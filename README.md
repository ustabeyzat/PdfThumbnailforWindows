# (EN) PDF Thumbnail Handler for Windows
A 64-bit COM thumbnail provider that displays thumbnails of PDF files in Windows File Explorer.

## Features
- Displays the first page of PDF files as a thumbnail.
- Does not require Adobe Acrobat or an external PDF rendering engine.
- Uses Windows' built-in PDF technology.
- Does not require an internet connection.
- Fully removable.

## Information
- For password-protected, corrupted, empty, or non-previewable PDF files, no thumbnail is shown;
the default Windows file icon is used instead.
- Thumbnail display must be enabled in File Explorer for thumbnails to appear.
- If the default PDF application changes, you may need to uninstall and reinstall.

* Because the DLL uses `VCRUNTIME140.dll`, "Microsoft Visual C++ v14 Redistributable (x64)" is required.
It is installed with vc_redist.x64.exe. download link: https://aka.ms/vc14/vc_redist.x64.exe

* Installation and uninstallation require administrator privileges.
- `Install.bat`: safe installation
If necessary, restart your computer or File Explorer (from Task Manager)

During installation, the DLL is copied to `C:\Program Files\PdfThumbnailForWindows`.
This is how it generates thumbnail previews of PDF files in File Explorer for Windows 10 and Windows 11 (64-bit).
program settings are kept under `%ProgramData%\PdfThumbnailForWindows`

- `Uninstall.bat`: safe uninstallation
If you wish, after completing the uninstallation you can delete the `%ProgramData%\PdfThumbnailForWindows` folder yourself.

- `PdfThumbnailHandler.dll`: ready-to-use PDF thumbnail component release DLL
- `source\`: Rust source files for those who want to rebuild the DLL
- This distribution uses the release DLL from the uploaded project; it does not modify the source code.
To rebuild the source code, Visual Studio 2022 C++ Build Tools, Windows SDK, and the Rust MSVC target are required. Project command:

```powershell
cargo build --release --target x86_64-pc-windows-msvc
```



# (TR) Windows'ta PDF küçük resimlerini gösterir
Windows Dosya Gezgini'nde PDF dosyalarının küçük resimlerini gösteren 64-bit COM thumbnail provider.

## Özellikler
- PDF dosyalarının ilk sayfasını küçük resim olarak gösterir.
- Adobe Acrobat veya harici PDF görüntüleme motoru gerektirmez.
- Windows'un yerleşik PDF teknolojisini kullanır.
- İnternet bağlantısı gerektirmez.
- Tamamen kaldırılabilir.

## Bilgiler
- Parola korumalı, bozuk, boş veya önizlemesi oluşturulamayan PDF dosyalarında küçük resim gösterilmez;
Windows'un varsayılan dosya simgesi kullanılır.
- Küçük resimlerin görünmesi için Dosya Gezgini'nde küçük resim gösterimi etkin olmalıdır.
- Varsayılan PDF uygulaması değişirse kaldırıp yeniden yüklemek gerekebilir.

* DLL `VCRUNTIME140.dll` kullandığı için "Microsoft Visual C++ v14 Redistributable (x64)" gereklidir.
vc_redist.x64.exe ile yüklenir. indirme linki: https://aka.ms/vc14/vc_redist.x64.exe

* Kurulum ve kaldırma yönetici izni gerektirir.
- `Install.bat`: güvenli kurulum
Gerekirse bilgisayarı yada Dosya Gezginini (Görev Yöneticisinden) yeniden başlatın

Kurulumda DLL `C:\Program Files\PdfThumbnailForWindows` altına kopyalanır.
Windows 10 ve Windows 11 (64-bit) için PDF dosyalarının Dosya Gezgini'nde küçük resim önizlemesini bu sayede oluşturur.
program ayarları `%ProgramData%\PdfThumbnailForWindows` altında tutulur.

- `Uninstall.bat`: güvenli kaldırma
İsterseniz kaldırmayı tamamladıktan sonra `%ProgramData%\PdfThumbnailForWindows` klasörünü kendiniz silebilirsiniz.

- `PdfThumbnailHandler.dll`: kullanima hazır PDF küçük resim bileşeni release DLL
- `source\`: DLL'yi yeniden derlemek isteyenler için Rust kaynak dosyalarıdır
- Bu dagitim, yuklenen projedeki release DLL'yi kullanir; kaynak kodu degistirmez.
Kaynak kodu yeniden derlemek icin Visual Studio 2022 C++ Build Tools, Windows SDK ve Rust MSVC hedefi gerekir. Proje komutu:

```powershell
cargo build --release --target x86_64-pc-windows-msvc
```
