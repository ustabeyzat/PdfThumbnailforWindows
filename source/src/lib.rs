use std::cell::RefCell;
use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::time::Duration;

use windows::core::{implement, Interface, IUnknown, GUID, HRESULT};

use windows::Win32::Foundation::{
    BOOL, CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION,
    E_FAIL, E_UNEXPECTED, S_FALSE, S_OK,
};

use windows::Win32::System::Com::{
    CoCreateInstance, CLSCTX_INPROC_SERVER,
    IClassFactory, IClassFactory_Impl, IStream,
};

use windows::Win32::System::WinRT::{
    RoInitialize, RoUninitialize,
    RO_INIT_MULTITHREADED,
    CreateStreamOverRandomAccessStream,
};

use windows::Win32::Graphics::Gdi::{
    CreateDIBSection, DeleteObject,
    BITMAPINFO, BITMAPINFOHEADER,
    BI_RGB, DIB_RGB_COLORS, HBITMAP, HDC,
};

use windows::Win32::Graphics::Imaging::{
    IWICImagingFactory, IWICPalette,
    CLSID_WICImagingFactory,
    GUID_WICPixelFormat32bppBGRA,
    WICBitmapDitherTypeNone,
    WICBitmapPaletteTypeCustom,
    WICDecodeMetadataCacheOnDemand,
};

use windows::Win32::UI::Shell::{
    IThumbnailProvider, IThumbnailProvider_Impl,
    WTS_ALPHATYPE, WTSAT_ARGB,
};

use windows::Win32::UI::Shell::PropertiesSystem::{
    IInitializeWithStream, IInitializeWithStream_Impl,
};

use windows::Foundation::{
    AsyncActionCompletedHandler, AsyncOperationCompletedHandler,
    AsyncStatus, IAsyncAction, IAsyncOperation,
};

use windows::Data::Pdf::{
    PdfDocument, PdfPageRenderOptions,
};

use windows::Storage::Streams::{
    InMemoryRandomAccessStream,
    DataWriter,
};

const CLSID_PDF_THUMBNAIL: GUID =
    GUID::from_u128(0x9b2e6f41_7c3a_4d85_a1f0_62c8b9e73410);

const WTS_E_FAILEDEXTRACTION: HRESULT =
    HRESULT(0x8004_B200u32 as i32);

const MAX_DIMENSION: u32 = 2048;
const MAX_IMAGE_BYTES: usize = 64 * 1024 * 1024;

static DLL_OBJECT_COUNT: AtomicU32 = AtomicU32::new(0);
static SERVER_LOCK_COUNT: AtomicU32 = AtomicU32::new(0);
static ACTIVE_WORKERS: AtomicU32 = AtomicU32::new(0);

const MAX_ACTIVE_WORKERS: u32 = 2;
const ASYNC_TIMEOUT: Duration = Duration::from_secs(20);
const WORKER_TIMEOUT: Duration = Duration::from_secs(90);

struct WinRtGuard;

impl WinRtGuard {
    fn initialize() -> windows::core::Result<Self> {
        unsafe {
            RoInitialize(RO_INIT_MULTITHREADED)?;
        }
        Ok(Self)
    }
}

impl Drop for WinRtGuard {
    fn drop(&mut self) {
        unsafe {
            RoUninitialize();
        }
    }
}

fn create_wic_bitmap(
    output: &InMemoryRandomAccessStream,
) -> windows::core::Result<usize> {
    let factory: IWICImagingFactory = unsafe {
        CoCreateInstance(
            &CLSID_WICImagingFactory,
            None::<&IUnknown>,
            CLSCTX_INPROC_SERVER,
        )?
    };

    let wic_stream: IStream = unsafe {
        CreateStreamOverRandomAccessStream::<_, IStream>(output)?
    };

    let decoder = unsafe {
        factory.CreateDecoderFromStream(
            &wic_stream,
            std::ptr::null(),
            WICDecodeMetadataCacheOnDemand,
        )?
    };

    let frame = unsafe {
        decoder.GetFrame(0)?
    };

    let converter = unsafe {
        factory.CreateFormatConverter()?
    };

    unsafe {
        converter.Initialize(
            &frame,
            &GUID_WICPixelFormat32bppBGRA,
            WICBitmapDitherTypeNone,
            None::<&IWICPalette>,
            0.0,
            WICBitmapPaletteTypeCustom,
        )?;
    }

    let mut width = 0u32;
    let mut height = 0u32;

    unsafe {
        converter.GetSize(&mut width, &mut height)?;
    }

    if width == 0
        || height == 0
        || width > MAX_DIMENSION
        || height > MAX_DIMENSION
    {
        return Err(WTS_E_FAILEDEXTRACTION.into());
    }

    let stride = width
        .checked_mul(4)
        .ok_or(WTS_E_FAILEDEXTRACTION)?;

    let image_bytes = (stride as usize)
        .checked_mul(height as usize)
        .ok_or(WTS_E_FAILEDEXTRACTION)?;

    if image_bytes == 0 || image_bytes > MAX_IMAGE_BYTES {
        return Err(WTS_E_FAILEDEXTRACTION.into());
    }

    let mut pixels = vec![0u8; image_bytes];

    unsafe {
        converter.CopyPixels(
            std::ptr::null(),
            stride,
            &mut pixels,
        )?;
    }

    let bitmap_info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: width as i32,
            biHeight: -(height as i32),
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            biSizeImage: image_bytes as u32,
            biXPelsPerMeter: 0,
            biYPelsPerMeter: 0,
            biClrUsed: 0,
            biClrImportant: 0,
        },
        bmiColors: Default::default(),
    };

    let mut bits: *mut c_void = std::ptr::null_mut();

    let bitmap: HBITMAP = unsafe {
        CreateDIBSection(
            HDC::default(),
            &bitmap_info,
            DIB_RGB_COLORS,
            &mut bits,
            None,
            0,
        )?
    };

    if bits.is_null() {
        unsafe {
            let _ = DeleteObject(bitmap);
        }
        return Err(E_FAIL.into());
    }

    unsafe {
        std::ptr::copy_nonoverlapping(
            pixels.as_ptr(),
            bits as *mut u8,
            image_bytes,
        );
    }

    Ok(bitmap.0 as usize)
}

struct WorkerSlot;

impl Drop for WorkerSlot {
    fn drop(&mut self) {
        ACTIVE_WORKERS.fetch_sub(1, Ordering::AcqRel);
    }
}

struct WorkerDllRef;

impl Drop for WorkerDllRef {
    fn drop(&mut self) {
        DLL_OBJECT_COUNT.fetch_sub(1, Ordering::AcqRel);
    }
}

fn reserve_worker() -> bool {
    let mut current = ACTIVE_WORKERS.load(Ordering::Acquire);

    loop {
        if current >= MAX_ACTIVE_WORKERS {
            return false;
        }

        match ACTIVE_WORKERS.compare_exchange_weak(
            current,
            current + 1,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            Ok(_) => return true,
            Err(next) => current = next,
        }
    }
}

fn wait_async_operation<TResult>(
    operation: IAsyncOperation<TResult>,
    timeout: Duration,
) -> windows::core::Result<TResult>
where
    TResult: windows::core::RuntimeType + 'static,
{
    let (tx, rx) = mpsc::channel();

    let handler = AsyncOperationCompletedHandler::<TResult>::new(
        move |_sender, status| {
            let _ = tx.send(status);
            Ok(())
        },
    );

    operation.SetCompleted(&handler)?;

    match rx.recv_timeout(timeout) {
        Ok(AsyncStatus::Completed) => operation.GetResults(),

        Ok(AsyncStatus::Error) | Ok(AsyncStatus::Canceled) => {
            operation.GetResults()
        }

        Ok(_) | Err(_) => {
            let _ = operation.Cancel();
            Err(WTS_E_FAILEDEXTRACTION.into())
        }
    }
}

fn wait_async_action(
    operation: IAsyncAction,
    timeout: Duration,
) -> windows::core::Result<()> {
    let (tx, rx) = mpsc::channel();

    let handler = AsyncActionCompletedHandler::new(
        move |_sender, status| {
            let _ = tx.send(status);
            Ok(())
        },
    );

    operation.SetCompleted(&handler)?;

    match rx.recv_timeout(timeout) {
        Ok(AsyncStatus::Completed) => operation.GetResults(),

        Ok(AsyncStatus::Error) | Ok(AsyncStatus::Canceled) => {
            operation.GetResults()
        }

        Ok(_) | Err(_) => {
            let _ = operation.Cancel();
            Err(WTS_E_FAILEDEXTRACTION.into())
        }
    }
}
fn inspect_pdf(
    pdf_bytes: Vec<u8>,
    requested_size: u32,
) -> windows::core::Result<usize> {
    let _winrt = WinRtGuard::initialize()?;

    if pdf_bytes.is_empty() {
        return Err(WTS_E_FAILEDEXTRACTION.into());
    }

    eprintln!("PDF: Bellek akisi olusturuluyor");

    eprintln!("PDF: 1 - InMemoryRandomAccessStream olusturuluyor");
    let output = InMemoryRandomAccessStream::new()?;
    eprintln!("PDF: 2 - Bellek akisi olusturuldu");

    let writer = DataWriter::CreateDataWriter(&output)?;
    eprintln!("PDF: 3 - DataWriter olusturuldu");

    writer.WriteBytes(&pdf_bytes)?;
    eprintln!("PDF: 4 - PDF baytlari yazildi");

    let stored_size = wait_async_operation(writer.StoreAsync()?.cast::<IAsyncOperation<u32>>()?, ASYNC_TIMEOUT)?;
    eprintln!("PDF: StoreAsync tamamlandi: {} bayt", stored_size);

    eprintln!("PDF: FlushAsync basliyor");
    match wait_async_operation(writer.FlushAsync()?, ASYNC_TIMEOUT) {
        Ok(value) => eprintln!("PDF: FlushAsync sonucu: {}", value),
        Err(error) => {
            eprintln!("PDF: FlushAsync HRESULT: 0x{:08X}", error.code().0 as u32);
            return Err(error);
        }
    }

    eprintln!("PDF: DetachStream basliyor");
    let detached = writer.DetachStream()?;
    drop(writer);
    drop(detached);

    eprintln!("PDF: Seek basliyor");
    output.Seek(0)?;
    eprintln!("PDF: Seek tamamlandi");

    eprintln!("PDF: WinRT akisina yazildi");

    let operation =
        PdfDocument::LoadFromStreamAsync(&output)?;

    eprintln!("PDF: Yukleme bekleniyor");

    let document = wait_async_operation(operation, ASYNC_TIMEOUT)?;

    eprintln!("PDF: Yuklendi");

    if document.PageCount()? == 0 {
        return Err(WTS_E_FAILEDEXTRACTION.into());
    }

    let page = document.GetPage(0)?;

    let page_size = page.Size()?;

    if !page_size.Width.is_finite()
        || !page_size.Height.is_finite()
        || page_size.Width <= 0.0
        || page_size.Height <= 0.0
    {
        return Err(WTS_E_FAILEDEXTRACTION.into());
    }

    let limit = requested_size.clamp(1, MAX_DIMENSION) as f32;

    let scale = (
        limit / page_size.Width.max(page_size.Height)
    ).min(1.0);

    let width = (page_size.Width * scale).ceil().max(1.0) as u32;
    let height = (page_size.Height * scale).ceil().max(1.0) as u32;

    let options = PdfPageRenderOptions::new()?;

    options.SetDestinationWidth(width)?;
    options.SetDestinationHeight(height)?;

    let rendered = InMemoryRandomAccessStream::new()?;

    eprintln!("PDF: Render basliyor");

    wait_async_action(
        page.RenderWithOptionsToStreamAsync(
            &rendered,
            &options,
        )?,
        ASYNC_TIMEOUT,
    )?;

    eprintln!("PDF: Render tamamlandi");

    let rendered_size = rendered.Size()?;

    if rendered_size == 0
        || rendered_size > MAX_IMAGE_BYTES as u64
    {
        return Err(WTS_E_FAILEDEXTRACTION.into());
    }

    rendered.Seek(0)?;

    create_wic_bitmap(&rendered)
}

#[implement(IThumbnailProvider, IInitializeWithStream)]
struct ThumbnailProvider {
    stream: RefCell<Option<IStream>>,
}

impl ThumbnailProvider {
    fn new() -> Self {
        DLL_OBJECT_COUNT.fetch_add(1, Ordering::SeqCst);

        Self {
            stream: RefCell::new(None),
        }
    }
}

impl Drop for ThumbnailProvider {
    fn drop(&mut self) {
        DLL_OBJECT_COUNT.fetch_sub(1, Ordering::SeqCst);
    }
}

impl IInitializeWithStream_Impl for ThumbnailProvider_Impl {
    fn Initialize(
        &self,
        stream: Option<&IStream>,
        _mode: u32,
    ) -> windows::core::Result<()> {
        match catch_unwind(AssertUnwindSafe(|| {
            let stream = stream.ok_or(E_FAIL)?;
            let mut stored = self.stream.borrow_mut();

            if stored.is_some() {
                return Err(E_FAIL.into());
            }

            *stored = Some(stream.clone());
            Ok(())
        })) {
            Ok(result) => result,
            Err(_) => Err(E_UNEXPECTED.into()),
        }
    }
}

    impl IThumbnailProvider_Impl for ThumbnailProvider_Impl {
        fn GetThumbnail(
            &self,
            cx: u32,
            bitmap: *mut HBITMAP,
            alpha: *mut WTS_ALPHATYPE,
        ) -> windows::core::Result<()> {
            match catch_unwind(AssertUnwindSafe(|| {
                unsafe {
                    if !bitmap.is_null() {
                        *bitmap = HBITMAP::default();
                    }

                    if !alpha.is_null() {
                        *alpha = WTS_ALPHATYPE(0);
                    }
                }

                if bitmap.is_null() || alpha.is_null() {
                    return Err(E_FAIL.into());
                }

                let stream_guard = self.stream.borrow();

                let original = stream_guard
                    .as_ref()
                    .ok_or(WTS_E_FAILEDEXTRACTION)?
                    .clone();

                drop(stream_guard);

                eprintln!("PDF: COM akisi okunuyor");

                let mut pdf_bytes = Vec::<u8>::new();

                loop {
                    let mut buffer = [0u8; 65536];
                    let mut bytes_read = 0u32;

                    unsafe {
                        original
                            .Read(
                                buffer.as_mut_ptr() as *mut c_void,
                                buffer.len() as u32,
                                Some(&mut bytes_read as *mut u32),
                            )
                            .ok()?;
                    }

                    if bytes_read == 0 {
                        break;
                    }

                    let new_size = pdf_bytes
                        .len()
                        .checked_add(bytes_read as usize)
                        .ok_or(WTS_E_FAILEDEXTRACTION)?;

                    if new_size > 128 * 1024 * 1024 {
                        return Err(WTS_E_FAILEDEXTRACTION.into());
                    }

                    pdf_bytes.extend_from_slice(
                        &buffer[..bytes_read as usize]
                    );
                }

                if pdf_bytes.is_empty() {
                    return Err(WTS_E_FAILEDEXTRACTION.into());
                }

                eprintln!(
                    "PDF: {} bayt okundu",
                    pdf_bytes.len()
                );

                if !reserve_worker() {
                    return Err(WTS_E_FAILEDEXTRACTION.into());
                }
                
                let (tx, rx) = mpsc::channel();
                
                DLL_OBJECT_COUNT.fetch_add(1, Ordering::AcqRel);
                let worker_slot = WorkerSlot;
                let worker_dll_ref = WorkerDllRef;
                
                std::thread::Builder::new()
                    .name("PdfThumbnailWorker".to_string())
                    .spawn(move || {
                        let _worker_slot = worker_slot;
                        let _worker_dll_ref = worker_dll_ref;
                
                        let result = inspect_pdf(pdf_bytes, cx);
                
                        if let Err(send_error) = tx.send(result) {
                            if let Ok(handle) = send_error.0 {
                                if handle != 0 {
                                    unsafe {
                                        let _ = DeleteObject(HBITMAP(handle as *mut c_void));
                                    }
                                }
                            }
                        }
                    })
                    .map_err(|_| E_FAIL)?;
                
                match rx.recv_timeout(WORKER_TIMEOUT) {
                    Ok(Ok(handle)) if handle != 0 => {
                        unsafe {
                            *bitmap = HBITMAP(handle as *mut c_void);
                            *alpha = WTSAT_ARGB;
                        }
                        eprintln!("PDF: Thumbnail basarili");
                        Ok(())
                    }
                    Ok(_) => Err(WTS_E_FAILEDEXTRACTION.into()),
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        eprintln!("PDF: Worker zaman asimina ugradi");
                        Err(WTS_E_FAILEDEXTRACTION.into())
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        Err(E_UNEXPECTED.into())
                    }
                }
            })) {
                Ok(result) => result,
                Err(_) => Err(E_UNEXPECTED.into()),
            }

    }
}

#[implement(IClassFactory)]
struct ThumbnailProviderFactory;

impl ThumbnailProviderFactory {
    fn new() -> Self {
        DLL_OBJECT_COUNT.fetch_add(1, Ordering::SeqCst);
        Self
    }
}

impl Drop for ThumbnailProviderFactory {
    fn drop(&mut self) {
        DLL_OBJECT_COUNT.fetch_sub(1, Ordering::SeqCst);
    }
}

impl IClassFactory_Impl for ThumbnailProviderFactory_Impl {
    fn CreateInstance(
        &self,
        outer: Option<&IUnknown>,
        riid: *const GUID,
        object: *mut *mut c_void,
    ) -> windows::core::Result<()> {
        match catch_unwind(AssertUnwindSafe(|| {
            if object.is_null() {
                return Err(E_FAIL.into());
            }

            unsafe {
                *object = std::ptr::null_mut();
            }

            if riid.is_null() {
                return Err(E_FAIL.into());
            }

            if outer.is_some() {
                return Err(CLASS_E_NOAGGREGATION.into());
            }

            let provider = ThumbnailProvider::new();
            let unknown: IUnknown = provider.into();

            unsafe {
                unknown.query(&*riid, object).ok()
            }
        })) {
            Ok(result) => result,
            Err(_) => Err(E_UNEXPECTED.into()),
        }
    }

    fn LockServer(&self, lock: BOOL) -> windows::core::Result<()> {
        match catch_unwind(AssertUnwindSafe(|| {
            if lock.as_bool() {
                SERVER_LOCK_COUNT.fetch_add(1, Ordering::SeqCst);
                return Ok(());
            }

            match SERVER_LOCK_COUNT.try_update(
                Ordering::SeqCst,
                Ordering::SeqCst,
                |current| current.checked_sub(1),
            ) {
                Ok(_) => Ok(()),
                Err(_) => Err(E_UNEXPECTED.into()),
            }
        })) {
            Ok(result) => result,
            Err(_) => Err(E_UNEXPECTED.into()),
        }
    }
}

#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(
    clsid: *const GUID,
    riid: *const GUID,
    object: *mut *mut c_void,
) -> HRESULT {
    if object.is_null() {
        return E_FAIL;
    }

    unsafe {
        *object = std::ptr::null_mut();
    }

    match catch_unwind(AssertUnwindSafe(|| {
        if clsid.is_null() || riid.is_null() {
            return E_FAIL;
        }

        if unsafe { *clsid } != CLSID_PDF_THUMBNAIL {
            return CLASS_E_CLASSNOTAVAILABLE;
        }

        let factory = ThumbnailProviderFactory::new();
        let unknown: IUnknown = factory.into();

        match unsafe { unknown.query(&*riid, object).ok() } {
            Ok(()) => S_OK,
            Err(error) => error.into(),
        }
    })) {
        Ok(result) => result,
        Err(_) => E_UNEXPECTED,
    }
}

#[no_mangle]
pub extern "system" fn DllCanUnloadNow() -> HRESULT {
    match catch_unwind(AssertUnwindSafe(|| {
        if DLL_OBJECT_COUNT.load(Ordering::SeqCst) == 0
            && SERVER_LOCK_COUNT.load(Ordering::SeqCst) == 0
        {
            S_OK
        } else {
            S_FALSE
        }
    })) {
        Ok(result) => result,
        Err(_) => E_UNEXPECTED,
    }
}
