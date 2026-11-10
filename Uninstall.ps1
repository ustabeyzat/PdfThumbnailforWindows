# PDF Thumbnail Handler - Kaldirma
# Windows 10/11 x64 - Windows PowerShell 5.1
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Owner = 'PdfThumbnailForWindows'
$Clsid = '{9B2E6F41-7C3A-4D85-A1F0-62C8B9E73410}'
$ThumbGuid = '{E357FCCD-A995-4576-B01F-234630154E96}'
$InstallDirectory = Join-Path $env:ProgramFiles 'PdfThumbnailForWindows'
$InstalledDll = Join-Path $InstallDirectory 'PdfThumbnailHandler.dll'
$StateDirectory = Join-Path $env:ProgramData 'PdfThumbnailForWindows'
$StateFile = Join-Path $StateDirectory 'InstallState.json'
$LegacyStateFile = Join-Path $env:ProgramData 'PdfThumbnailHandler\RegistryBackup.json'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Kaldırma yönetici izni gerektirir. Uninstall.bat dosyasına çift tıklayın ve Windows izin sorusunu onaylayın.'
    }
}

function Get-ValueInfo {
    param([Microsoft.Win32.RegistryKey]$Root, [string]$Path, [string]$Name)
    $key = $Root.OpenSubKey($Path, $false)
    if ($null -eq $key) { return [pscustomobject]@{ Present = $false; Kind = $null; Data = $null } }
    try {
        if ($key.GetValueNames() -notcontains $Name) { return [pscustomobject]@{ Present = $false; Kind = $null; Data = $null } }
        return [pscustomobject]@{
            Present = $true
            Kind = $key.GetValueKind($Name).ToString()
            Data = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    }
    finally { $key.Dispose() }
}

function Restore-Snapshot {
    param([Microsoft.Win32.RegistryKey]$Root, $Snapshot)
    $key = $Root.OpenSubKey([string]$Snapshot.Path, $true)
    if ($null -eq $key) { $key = $Root.CreateSubKey([string]$Snapshot.Path) }
    if ($null -eq $key) { throw "Kayıt anahtarı açılamadı: $($Snapshot.Path)" }
    try {
        foreach ($entry in @($Snapshot.Values)) {
            if ($entry.Present) {
                $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$entry.Kind)
                $key.SetValue([string]$entry.Name, $entry.Data, $kind)
            }
            else {
                $key.DeleteValue([string]$entry.Name, $false)
            }
        }
        $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
    }
    finally { $key.Dispose() }

    if (-not $Snapshot.KeyExisted -and $empty) {
        $parentPath = Split-Path ([string]$Snapshot.Path) -Parent
        $leaf = Split-Path ([string]$Snapshot.Path) -Leaf
        $parent = $Root.OpenSubKey($parentPath, $true)
        if ($parent) { try { $parent.DeleteSubKey($leaf, $false) } catch {} finally { $parent.Dispose() } }
    }
}

function Notify-Shell {
    if (-not ('PdfThumbnailShellNotify' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PdfThumbnailShellNotify {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
}
'@
    }
    [PdfThumbnailShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Schedule-DeleteAtRestart {
    param([string]$Path)
    if (-not ('PdfThumbnailDelayedDelete' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PdfThumbnailDelayedDelete {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool MoveFileEx(string existingName, string newName, int flags);
}
'@
    }
    return [PdfThumbnailDelayedDelete]::MoveFileEx($Path, $null, 0x4)
}

function Remove-LegacyInstallV1 {
    if (-not (Test-Path -LiteralPath $LegacyStateFile -PathType Leaf)) { return $false }
    $legacy = Get-Content -LiteralPath $LegacyStateFile -Raw | ConvertFrom-Json
    if ($legacy.Owner -ne $Owner -or $legacy.FormatVersion -ne 1 -or
        $legacy.Clsid -ne $Clsid -or $legacy.ThumbnailProviderGuid -ne $ThumbGuid -or
        $legacy.AssociationHive -ne 'HKEY_CURRENT_USER' -or $legacy.ComHive -ne 'HKEY_LOCAL_MACHINE' -or
        $legacy.RegistryView -ne 'Registry64' -or
        $legacy.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or
        [string]$legacy.ProgId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Önceki kurulum kaydı doğrulanamadı; kayıtlar silinmedi: $LegacyStateFile"
    }
    $userRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
    $machineRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $assocPath = "Software\Classes\$($legacy.ProgId)\ShellEx\$ThumbGuid"
        $assoc = $userRoot.OpenSubKey($assocPath, $false)
        if ($assoc) {
            $names = @($assoc.GetValueNames()); $children = @($assoc.GetSubKeyNames())
            $owned = ($names.Count -eq 1 -and $names[0] -ceq '' -and $children.Count -eq 0 -and
                $assoc.GetValueKind('') -eq [Microsoft.Win32.RegistryValueKind]::String -and $assoc.GetValue('') -ceq $Clsid)
            $assoc.Dispose()
            if ($owned) { $userRoot.DeleteSubKeyTree($assocPath, $false) }
            else { Write-Warning "Eski ProgID kaydı değişmiş; korunuyor: $assocPath" }
        }
        $classPath = "SOFTWARE\Classes\CLSID\$Clsid"
        $inprocPath = "$classPath\InprocServer32"
        $server = $machineRoot.OpenSubKey($inprocPath, $false)
        if ($server) {
            $names = @($server.GetValueNames()); $children = @($server.GetSubKeyNames())
            $owned = ($children.Count -eq 0 -and $names.Count -eq 2 -and $names -contains '' -and $names -contains 'ThreadingModel' -and
                $server.GetValueKind('') -eq [Microsoft.Win32.RegistryValueKind]::String -and
                $server.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq [string]$legacy.DllPath -and
                $server.GetValueKind('ThreadingModel') -eq [Microsoft.Win32.RegistryValueKind]::String -and $server.GetValue('ThreadingModel') -ceq 'Apartment')
            $server.Dispose()
            if ($owned) {
                $class = $machineRoot.OpenSubKey($classPath, $false)
                if ($class) {
                    $parentValues = @($class.GetValueNames())
                    $parentChildren = @($class.GetSubKeyNames())
                    $class.Dispose()
                    if ($parentValues.Count -eq 0 -and $parentChildren.Count -eq 1 -and $parentChildren[0] -ceq 'InprocServer32') {
                        $machineRoot.DeleteSubKeyTree($classPath, $false)
                    }
                    else { Write-Warning 'Eski CLSID anahtarında başka kayıt var; korunuyor.' }
                }
            }
            else { Write-Warning 'Eski CLSID kaydı değişmiş; korunuyor.' }
        }
    }
    finally { $userRoot.Dispose(); $machineRoot.Dispose() }

    if ((Test-Path -LiteralPath ([string]$legacy.DllPath) -PathType Leaf) -and $legacy.DllSha256) {
        if ((Get-FileHash -LiteralPath ([string]$legacy.DllPath) -Algorithm SHA256).Hash -eq [string]$legacy.DllSha256) {
            try { Remove-Item -LiteralPath ([string]$legacy.DllPath) -Force -ErrorAction Stop }
            catch {
                if (Schedule-DeleteAtRestart -Path ([string]$legacy.DllPath)) { Write-Host 'Eski DLL yeniden başlatmada silinecek.' }
                else { Write-Warning "Eski DLL silinemedi: $($legacy.DllPath)" }
            }
        }
        else { Write-Warning 'Eski DLL hash eşleşmedi; dosya korundu.' }
    }
    # ConvertFrom-Json creates a PSCustomObject. Add uninstall metadata safely
    # even when the older state file has never contained these properties.
    Add-Member -InputObject $legacy -MemberType NoteProperty -Name 'Installed' -Value $false -Force
    Add-Member -InputObject $legacy -MemberType NoteProperty -Name 'UninstalledByVersion2' -Value ([DateTime]::UtcNow.ToString('o')) -Force
    [IO.File]::WriteAllText($LegacyStateFile, ($legacy | ConvertTo-Json -Depth 20), ([System.Text.UTF8Encoding]::new($false)))
    return $true
}

$machineRoot = $null
$userRoot = $null

try {
    Assert-Administrator
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw '64-bit Windows PowerShell gereklidir.' }

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        if (Remove-LegacyInstallV1) {
            Notify-Shell
            Write-Host ''
            Write-Host 'Önceki PDF Thumbnail Handler kurulumu kaldırıldı.' -ForegroundColor Green
        }
        else {
            throw "Kurulum kaydı bulunamadı. Yanlış klasörden çalıştırılmış olabilir veya uygulama zaten kaldırılmıştır."
        }
    }
    else {
        $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        if ($state.FormatVersion -ne 2 -or $state.Owner -ne $Owner -or
            $state.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or
            $state.Clsid -ne $Clsid -or $state.ThumbnailProviderGuid -ne $ThumbGuid -or
            [IO.Path]::GetFullPath([string]$state.DllPath) -ine [IO.Path]::GetFullPath($InstalledDll)) {
            throw 'Kurulum yedegi doğrulanamadı; hiçbir kayıt silinmedi.'
        }
        if ($state.Installed -ne $true) {
            Write-Host 'PDF Thumbnail Handler zaten kaldırılmış.' -ForegroundColor Yellow
            Read-Host 'Pencereyi kapatmak için Enter tuşuna basın' | Out-Null
            return
        }
        if (Test-Path -LiteralPath $InstalledDll -PathType Leaf) {
            $currentHash = (Get-FileHash -LiteralPath $InstalledDll -Algorithm SHA256).Hash
            if ($currentHash -ne [string]$state.DllSha256) { throw 'Kurulu DLL değişmiş; güvenlik için dosyaya ve kayıtlara dokunulmadı.' }
        }

        $machineRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $userRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            # Önce tüm hedeflerin sahipliğini kontrol et; bir hedef değişmişse yalnızca o hedef korunur.
            foreach ($item in @($state.Associations)) {
                $path = [string]$item.Path
                $value = Get-ValueInfo -Root $userRoot -Path $path -Name ''
                if ($value.Present -and [string]$value.Data -ceq $Clsid) {
                    try { Restore-Snapshot -Root $userRoot -Snapshot $item.Snapshot }
                    catch { Write-Warning "Kayıt geri yüklenemedi; korunuyor: $path. Ayrıntı: $_" }
                }
                elseif ($value.Present) { Write-Warning "Kayıt bu kurulumdan sonra değişmiş; üzerine yazılmadı: $path" }
            }

            $classPath = "SOFTWARE\Classes\CLSID\$Clsid"
            $inprocPath = "$classPath\InprocServer32"
            $server = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name ''
            $thread = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name 'ThreadingModel'
            if ($server.Present -and [string]$server.Data -ceq [string]$state.DllPath -and
                ((-not $thread.Present) -or [string]$thread.Data -ceq 'Apartment')) {
                Restore-Snapshot -Root $machineRoot -Snapshot $state.ComSnapshot
                $class = $machineRoot.OpenSubKey($classPath, $false)
                if ($class) {
                    $emptyClass = ($class.ValueCount -eq 0 -and $class.SubKeyCount -eq 0)
                    $class.Dispose()
                    if ($emptyClass) { $parent = $machineRoot.OpenSubKey('SOFTWARE\Classes\CLSID', $true); if ($parent) { $parent.DeleteSubKey([string]$Clsid, $false); $parent.Dispose() } }
                }
            }
            elseif ($server.Present) { Write-Warning 'COM kaydı değişmiş; yabancı kayıt korunuyor.' }
        }
        finally { $userRoot.Dispose(); $machineRoot.Dispose() }

        $pendingDelete = $false
        if (Test-Path -LiteralPath $InstalledDll -PathType Leaf) {
            $currentHash = (Get-FileHash -LiteralPath $InstalledDll -Algorithm SHA256).Hash
            if ($currentHash -eq [string]$state.DllSha256) {
                try { Remove-Item -LiteralPath $InstalledDll -Force -ErrorAction Stop }
                catch {
                    if (Schedule-DeleteAtRestart -Path $InstalledDll) { $pendingDelete = $true }
                    else { Write-Warning "DLL silinemedi: $InstalledDll" }
                }
            }
            else { Write-Warning 'DLL hash eşleşmedi; dosya korundu.' }
        }
        # ConvertFrom-Json returns a PSCustomObject. Older state files do not
        # contain uninstall metadata, so add/update these NoteProperties safely.
        Add-Member -InputObject $state -MemberType NoteProperty -Name 'Installed' -Value $false -Force
        Add-Member -InputObject $state -MemberType NoteProperty -Name 'UninstalledUtc' -Value ([DateTime]::UtcNow.ToString('o')) -Force
        Add-Member -InputObject $state -MemberType NoteProperty -Name 'PendingDllDeleteAtRestart' -Value $pendingDelete -Force
        [IO.File]::WriteAllText($StateFile, ($state | ConvertTo-Json -Depth 20), ([System.Text.UTF8Encoding]::new($false)))
        if (Test-Path -LiteralPath $InstallDirectory) {
            if (@(Get-ChildItem -LiteralPath $InstallDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $InstallDirectory -Force }
        }
        Notify-Shell
        Write-Host ''
        Write-Host 'PDF KÜÇÜK RESİM SAĞLAYICISI KALDIRILDI' -ForegroundColor Green
        Write-Host 'Varsayılan PDF uygulaması değiştirilmedi.'
        if ($pendingDelete) { Write-Host 'DLL Explorer tarafından kullanıldığı için bilgisayar yeniden başlatıldığında silinecek.' }
        Write-Host "Durum/yedek dosyası korundu: $StateFile"
    }
}
catch {
    Write-Host ''
    Write-Host ('KALDIRMA HATASI: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Hiçbir yabancı kayıt zorla silinmedi.'
    Read-Host 'Hata oluştu. Ayrıntıları not ettikten sonra Enter tuşuna basın' | Out-Null
    exit 1
}
finally {
    if ($userRoot) { $userRoot.Dispose() }
    if ($machineRoot) { $machineRoot.Dispose() }
}

Read-Host 'İşlem tamamlandı. Bu pencereyi kapatmak için Enter tuşuna basın' | Out-Null
