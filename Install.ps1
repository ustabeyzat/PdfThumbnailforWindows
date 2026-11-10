# PDF Thumbnail Handler - Kurulum
# Windows 10/11 x64 - Windows PowerShell 5.1
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$Owner = 'PdfThumbnailForWindows'
$Clsid = '{9B2E6F41-7C3A-4D85-A1F0-62C8B9E73410}'
$ThumbGuid = '{E357FCCD-A995-4576-B01F-234630154E96}'
$LegacyClsid = '{6D4E3A91-7C52-4B8E-9F13-2A6D8C5B7041}'
$SourceDll = Join-Path $PSScriptRoot 'PdfThumbnailHandler.dll'
$InstallDirectory = Join-Path $env:ProgramFiles 'PdfThumbnailForWindows'
$InstalledDll = Join-Path $InstallDirectory 'PdfThumbnailHandler.dll'
$StateDirectory = Join-Path $env:ProgramData 'PdfThumbnailForWindows'
$StateFile = Join-Path $StateDirectory 'InstallState.json'
$LegacyStateFile = Join-Path $env:ProgramData 'PdfThumbnailHandler\RegistryBackup.json'
$UserChoicePath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.pdf\UserChoice'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Kurulum yönetici izni gerektirir. Install.bat dosyasına çift tıklayın ve Windows izin sorusunu onaylayın.'
    }
}

function Test-Pe64Dll {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($stream.Length -lt 256 -or $reader.ReadUInt16() -ne 0x5A4D) { throw 'DLL geçerli bir Windows PE dosyası değil.' }
        $stream.Position = 0x3C
        $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'DLL PE başlığı geçersiz.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x00004550) { throw 'DLL PE imzası geçersiz.' }
        $machine = $reader.ReadUInt16()
        if ($machine -ne 0x8664) { throw ('DLL x64 değil. PE Machine: 0x{0:X4}' -f $machine) }
    }
    finally { $reader.Dispose(); $stream.Dispose() }
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

function Get-KeySnapshot {
    param([Microsoft.Win32.RegistryKey]$Root, [string]$Path, [string[]]$Names)
    $key = $Root.OpenSubKey($Path, $false)
    $exists = $null -ne $key
    $values = @()
    foreach ($name in $Names) {
        if ($null -ne $key -and $key.GetValueNames() -contains $name) {
            $values += [pscustomobject]@{
                Name = $name
                Present = $true
                Kind = $key.GetValueKind($name).ToString()
                Data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
        }
        else {
            $values += [pscustomobject]@{ Name = $name; Present = $false; Kind = $null; Data = $null }
        }
    }
    if ($key) { $key.Dispose() }
    return [pscustomobject]@{ Path = $Path; KeyExisted = $exists; Values = @($values) }
}

function Set-RegistryString {
    param([Microsoft.Win32.RegistryKey]$Root, [string]$Path, [string]$Name, [string]$Value)
    $key = $Root.CreateSubKey($Path)
    if ($null -eq $key) { throw "Kayıt anahtarı oluşturulamadı: $Path" }
    try { $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $key.Dispose() }
}

function Save-StateFile {
    param($State)
    $json = $State | ConvertTo-Json -Depth 12
    $temp = "$StateFile.tmp"
    [IO.File]::WriteAllText($temp, $json, ([System.Text.UTF8Encoding]::new($false)))
    Move-Item -LiteralPath $temp -Destination $StateFile -Force
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


function Remove-LegacyPerUserV0 {
    param([Microsoft.Win32.RegistryKey]$UserRoot)
    $oldDirectory = Join-Path $env:LOCALAPPDATA 'PdfThumbnailHandler'
    $oldBackup = Join-Path $oldDirectory 'registry-backup.json'
    $oldDll = Join-Path $oldDirectory 'PdfThumbnailHandler.dll'
    if (-not (Test-Path -LiteralPath $oldBackup -PathType Leaf)) { return }

    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = 1048576
    $backup = $serializer.DeserializeObject([IO.File]::ReadAllText($oldBackup))
    if ($null -eq $backup -or -not $backup.ContainsKey('Keys') -or $backup['Keys'].Count -ne 2) {
        throw "Eski kullanıcı kurulumu yedeği doğrulanamadı; değiştirilmedi: $oldBackup"
    }

    $oldAssocPath = "Software\Classes\.pdf\ShellEx\$ThumbGuid"
    $oldInprocPath = "Software\Classes\CLSID\$LegacyClsid\InprocServer32"
    $assocEntry = $null; $inprocEntry = $null
    foreach ($entry in $backup['Keys']) {
        if ([string]$entry['Path'] -ieq $oldAssocPath) { $assocEntry = $entry }
        elseif ([string]$entry['Path'] -ieq $oldInprocPath) { $inprocEntry = $entry }
        else { throw 'Eski kurulum yedeğinde tanınmayan kayıt yolu var; hiçbir şey değiştirilmedi.' }
    }
    if ($null -eq $assocEntry -or $null -eq $inprocEntry) { throw 'Eski kurulum yedeğinde gerekli kayıtlar eksik; hiçbir şey değiştirilmedi.' }

    $assoc = $UserRoot.OpenSubKey($oldAssocPath, $false)
    if ($assoc) {
        $names = @($assoc.GetValueNames()); $children = @($assoc.GetSubKeyNames())
        $owned = ($names.Count -eq 1 -and $names[0] -ceq '' -and $children.Count -eq 0 -and
            $assoc.GetValueKind('') -eq [Microsoft.Win32.RegistryValueKind]::String -and $assoc.GetValue('') -ceq $LegacyClsid)
        $assoc.Dispose()
        if (-not $owned) { throw 'Eski .pdf thumbnail kaydı değişmiş; güvenlik için yeni kurulum durduruldu.' }
    }

    $server = $UserRoot.OpenSubKey($oldInprocPath, $false)
    if ($server) {
        $names = @($server.GetValueNames()); $children = @($server.GetSubKeyNames())
        $owned = ($names.Count -eq 2 -and $names -contains '' -and $names -contains 'ThreadingModel' -and $children.Count -eq 0 -and
            $server.GetValueKind('') -eq [Microsoft.Win32.RegistryValueKind]::String -and
            $server.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq $oldDll -and
            $server.GetValueKind('ThreadingModel') -eq [Microsoft.Win32.RegistryValueKind]::String -and $server.GetValue('ThreadingModel') -ceq 'Apartment')
        $server.Dispose()
        if (-not $owned) { throw 'Eski COM kaydı değişmiş; güvenlik için yeni kurulum durduruldu.' }
    }

    foreach ($entry in @($assocEntry, $inprocEntry)) {
        $path = [string]$entry['Path']
        $key = $UserRoot.OpenSubKey($path, $true)
        if ($null -eq $key) { $key = $UserRoot.CreateSubKey($path) }
        if ($null -eq $key) { throw "Eski kayıt geri yüklenemedi: $path" }
        foreach ($name in $entry['Values'].Keys) {
            $saved = $entry['Values'][$name]
            if ($saved['Present']) {
                $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$saved['Kind'])
                $key.SetValue([string]$name, $saved['Data'], $kind)
            }
            else { $key.DeleteValue([string]$name, $false) }
        }
        $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
        $key.Dispose()
        if (-not $entry['Exists'] -and $empty) {
            $parentPath = Split-Path $path -Parent; $leaf = Split-Path $path -Leaf
            $parent = $UserRoot.OpenSubKey($parentPath, $true)
            if ($parent) { try { $parent.DeleteSubKey($leaf, $false) } catch {} finally { $parent.Dispose() } }
        }
    }

    $originalServer = $inprocEntry['Values']['']
    $oldDllWasOriginal = ($inprocEntry['Exists'] -and $originalServer['Present'] -and [string]$originalServer['Data'] -ieq $oldDll)
    if (-not $oldDllWasOriginal -and (Test-Path -LiteralPath $oldDll -PathType Leaf)) {
        try { Remove-Item -LiteralPath $oldDll -Force -ErrorAction Stop }
        catch {
            if (-not (Schedule-DeleteAtRestart -Path $oldDll)) { Write-Warning "Eski DLL kaldırılamadı: $oldDll" }
            else { Write-Host 'Eski sürümün DLL dosyası yeniden başlatmada silinecek.' }
        }
    }
    Remove-Item -LiteralPath $oldBackup -Force
    if (Test-Path -LiteralPath $oldDirectory) {
        if (@(Get-ChildItem -LiteralPath $oldDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $oldDirectory -Force }
    }
    Write-Host 'Önceki kullanıcı düzeyindeki kurulumun kayıtları geri alındı.' -ForegroundColor Green
}

function Remove-LegacyInstallV1 {
    if (-not (Test-Path -LiteralPath $LegacyStateFile -PathType Leaf)) { return }
    $legacy = Get-Content -LiteralPath $LegacyStateFile -Raw | ConvertFrom-Json
    if ($legacy.Owner -ne $Owner -or $legacy.FormatVersion -ne 1 -or
        $legacy.Clsid -ne $Clsid -or $legacy.ThumbnailProviderGuid -ne $ThumbGuid -or
        $legacy.AssociationHive -ne 'HKEY_CURRENT_USER' -or $legacy.ComHive -ne 'HKEY_LOCAL_MACHINE' -or
        $legacy.RegistryView -ne 'Registry64' -or
        $legacy.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or
        [string]$legacy.ProgId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Önceki kurulum kaydı doğrulanamadı; eski kayıtlar değiştirilmedi: $LegacyStateFile"
    }

    $userRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
    $machineRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $assocPath = "Software\Classes\$($legacy.ProgId)\ShellEx\$ThumbGuid"
        $assoc = $userRoot.OpenSubKey($assocPath, $false)
        if ($assoc) {
            $names = @($assoc.GetValueNames())
            $children = @($assoc.GetSubKeyNames())
            $owned = ($names.Count -eq 1 -and $names[0] -ceq '' -and $children.Count -eq 0 -and
                $assoc.GetValueKind('') -eq [Microsoft.Win32.RegistryValueKind]::String -and
                $assoc.GetValue('') -ceq $Clsid)
            $assoc.Dispose()
            if ($owned) { $userRoot.DeleteSubKeyTree($assocPath, $false) }
            else { Write-Warning "Önceki ProgID kaydı değişmiş; korunuyor: $assocPath" }
        }

        $classPath = "SOFTWARE\Classes\CLSID\$Clsid"
        $inprocPath = "$classPath\InprocServer32"
        $server = $machineRoot.OpenSubKey($inprocPath, $false)
        if ($server) {
            $names = @($server.GetValueNames())
            $children = @($server.GetSubKeyNames())
            $expectedDll = [string]$legacy.DllPath
            $owned = ($children.Count -eq 0 -and $names.Count -eq 2 -and $names -contains '' -and $names -contains 'ThreadingModel' -and
                $server.GetValueKind('') -eq [Microsoft.Win32.RegistryValueKind]::String -and
                $server.GetValue('', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq $expectedDll -and
                $server.GetValueKind('ThreadingModel') -eq [Microsoft.Win32.RegistryValueKind]::String -and
                $server.GetValue('ThreadingModel') -ceq 'Apartment')
            $server.Dispose()
            if ($owned) {
                $class = $machineRoot.OpenSubKey($classPath, $false)
                if ($class) {
                    $parentValues = @($class.GetValueNames())
                    $parentChildren = @($class.GetSubKeyNames())
                    $class.Dispose()
                    if ($parentValues.Count -ne 0 -or $parentChildren.Count -ne 1 -or $parentChildren[0] -cne 'InprocServer32') {
                        throw 'Önceki CLSID anahtarında başka veri var; güvenlik için yeni kurulum durduruldu.'
                    }
                }
                $machineRoot.DeleteSubKeyTree($classPath, $false)
            }
            else { throw 'Önceki CLSID kaydı beklenenden farklı; güvenlik için yeni kurulum durduruldu.' }
        }
    }
    finally { $userRoot.Dispose(); $machineRoot.Dispose() }

    if (Test-Path -LiteralPath ([string]$legacy.DllPath) -PathType Leaf) {
        $removeOld = $false
        if ($legacy.DllSha256) {
            $oldHash = (Get-FileHash -LiteralPath ([string]$legacy.DllPath) -Algorithm SHA256).Hash
            $removeOld = ($oldHash -eq [string]$legacy.DllSha256)
        }
        if ($removeOld) {
            try { Remove-Item -LiteralPath ([string]$legacy.DllPath) -Force -ErrorAction Stop }
            catch {
                if (-not (Schedule-DeleteAtRestart -Path ([string]$legacy.DllPath))) {
                    Write-Warning "Eski DLL kaldırılamadı; yeniden başlatmada da silinmesi planlanamadı: $($legacy.DllPath)"
                }
                else { Write-Host 'Eski DLL, Explorer kullandığı için yeniden başlatmada silinecek.' }
            }
        }
        else { Write-Warning 'Eski DLL hash doğrulaması eşleşmedi; dosya korundu.' }
    }

    # ConvertFrom-Json creates a PSCustomObject. Add migration metadata as NoteProperties
    # instead of assigning properties that do not exist in the older state file.
    Add-Member -InputObject $legacy -MemberType NoteProperty -Name 'Installed' -Value $false -Force
    Add-Member -InputObject $legacy -MemberType NoteProperty -Name 'MigratedTo' -Value '2.0' -Force
    Add-Member -InputObject $legacy -MemberType NoteProperty -Name 'MigratedUtc' -Value ([DateTime]::UtcNow.ToString('o')) -Force
    [IO.File]::WriteAllText($LegacyStateFile, ($legacy | ConvertTo-Json -Depth 20), ([System.Text.UTF8Encoding]::new($false)))
    Write-Host 'Önceki sürümün kayıtları güvenli şekilde temizlendi.' -ForegroundColor Green
}

$machineRoot = $null
$userRoot = $null
$copiedDll = $false
$stateWritten = $false
$associationSnapshots = @()
$comSnapshot = $null
$sourceHash = $null

try {
    Assert-Administrator
    if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) {
        throw 'Bu paket yalnızca 64-bit Windows içindir.'
    }
    if (-not (Test-Path -LiteralPath $SourceDll -PathType Leaf)) { throw "Paket DLL dosyası bulunamadı: $SourceDll" }
    Test-Pe64Dll -Path $SourceDll
    if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\VCRUNTIME140.dll') -PathType Leaf)) {
        throw 'Microsoft Visual C++ x64 Runtime bu bilgisayarda bulunamadı. Önce şu Microsoft paketini kurun: https://aka.ms/vc14/vc_redist.x64.exe'
    }

    $sourceHash = (Get-FileHash -LiteralPath $SourceDll -Algorithm SHA256).Hash
    $machineRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    $userRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)

    if (Test-Path -LiteralPath $StateFile -PathType Leaf) {
        $oldState = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        if ($oldState.Owner -ne $Owner -or $oldState.FormatVersion -ne 2 -or
            $oldState.UserSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
            throw "Kurulum durum dosyası tanınmıyor; üzerine yazılmadı: $StateFile"
        }
        if ($oldState.Installed -eq $true) {
            if ($oldState.DllSha256 -ne $sourceHash) {
                throw 'Farklı bir sürüm kurulu. Önce Uninstall.bat dosyasını çalıştırın.'
            }
            if (Test-Path -LiteralPath $InstalledDll -PathType Leaf) {
                if ((Get-FileHash -LiteralPath $InstalledDll -Algorithm SHA256).Hash -ne $sourceHash) {
                    throw 'Kurulu DLL beklenen sürümden farklı; üzerine yazılmadı.'
                }
            }
            else {
                New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
                Copy-Item -LiteralPath $SourceDll -Destination $InstalledDll
            }
            if ($null -eq $oldState.Associations -or @($oldState.Associations).Count -lt 2) {
                throw 'Kurulum yedeğinde PDF ilişkilendirme kayıtları eksik; hiçbir kayıt değiştirilmedi.'
            }
            $requiredPaths = @(
                'Software\Classes\.pdf\ShellEx\' + $ThumbGuid,
                'Software\Classes\SystemFileAssociations\.pdf\ShellEx\' + $ThumbGuid
            )
            $optionalProgIdPath = $null
            if ([string]$oldState.ProgIdAtInstall -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
                $optionalProgIdPath = "Software\Classes\$($oldState.ProgIdAtInstall)\ShellEx\$ThumbGuid"
            }
            $repairItems = @()
            foreach ($item in @($oldState.Associations)) {
                $path = [string]$item.Path
                if (($requiredPaths -notcontains $path) -and ($null -eq $optionalProgIdPath -or $path -ine $optionalProgIdPath)) {
                    throw "Kurulum yedeğinde beklenmeyen kayıt yolu var; hiçbir kayıt değiştirilmedi: $path"
                }
                $current = Get-ValueInfo -Root $userRoot -Path $path -Name ''
                if ($current.Present -and [string]$current.Data -cne $Clsid) {
                    if ($null -ne $optionalProgIdPath -and $path -ieq $optionalProgIdPath) {
                        Write-Warning "Varsayılanı değişmiş eski PDF uygulamasının kaydı korundu: $path"
                        continue
                    }
                    throw "Kayıt başka bir sağlayıcıya ait; üzerine yazılmadı: $path"
                }
                $repairItems += $item
            }
            foreach ($requiredPath in $requiredPaths) {
                if (@($oldState.Associations | Where-Object { [string]$_.Path -ieq $requiredPath }).Count -eq 0) {
                    throw "Kurulum yedeğinde gerekli genel PDF kaydı eksik: $requiredPath"
                }
            }
            $classPath = "SOFTWARE\Classes\CLSID\$Clsid"
            $inprocPath = "$classPath\InprocServer32"
            $server = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name ''
            $thread = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name 'ThreadingModel'
            if ($server.Present -and [string]$server.Data -cne $InstalledDll) {
                throw 'CLSID başka bir DLL yoluna kayıtlı; üzerine yazılmadı.'
            }
            if ($thread.Present -and [string]$thread.Data -cne 'Apartment') {
                throw 'CLSID ThreadingModel değeri beklenenden farklı; üzerine yazılmadı.'
            }
            foreach ($item in $repairItems) {
                Set-RegistryString -Root $userRoot -Path ([string]$item.Path) -Name '' -Value $Clsid
            }
            Set-RegistryString -Root $machineRoot -Path $inprocPath -Name '' -Value $InstalledDll
            Set-RegistryString -Root $machineRoot -Path $inprocPath -Name 'ThreadingModel' -Value 'Apartment'
            Notify-Shell
            Write-Host 'PDF Thumbnail Handler kayitlari onarildi; kurulum zaten mevcut DLL uzerinden yenilendi.' -ForegroundColor Green
            Write-Host 'Varsayilan PDF uygulamasi degistirilmedi.'
            Read-Host 'Pencereyi kapatmak icin Enter tusuna basin' | Out-Null
            return
        }
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $StateFile -Destination (Join-Path $StateDirectory "InstallState-$stamp.json")
    }

    # Daha önceki kullanıcı düzeyindeki paketi ve ardından eski v1 makine kurulumunu güvenli biçimde taşı.
    Remove-LegacyPerUserV0 -UserRoot $userRoot
    Remove-LegacyInstallV1

    if (Test-Path -LiteralPath $InstalledDll -PathType Leaf) {
        $existingHash = (Get-FileHash -LiteralPath $InstalledDll -Algorithm SHA256).Hash
        if ($existingHash -ne $sourceHash) { throw "Kurulum klasöründe farklı bir DLL var; üzerine yazılmadı: $InstalledDll" }
    }

    $progId = $null
    $choice = $userRoot.OpenSubKey($UserChoicePath, $false)
    if ($choice) {
        try {
            $candidate = [string]$choice.GetValue('ProgId')
            if ($candidate -match '^[A-Za-z0-9][A-Za-z0-9._-]*$') { $progId = $candidate }
        }
        finally { $choice.Dispose() }
    }

    $assocPaths = @(
        'Software\Classes\.pdf\ShellEx\' + $ThumbGuid,
        'Software\Classes\SystemFileAssociations\.pdf\ShellEx\' + $ThumbGuid
    )
    if ($progId) { $assocPaths += "Software\Classes\$progId\ShellEx\$ThumbGuid" }
    $assocPaths = @($assocPaths | Select-Object -Unique)

    foreach ($path in $assocPaths) {
        $current = Get-ValueInfo -Root $userRoot -Path $path -Name ''
        if ($current.Present -and [string]$current.Data -cne $Clsid) {
            if ($path -like "Software\Classes\$progId\ShellEx\*") {
                Write-Warning "Bu PDF uygulamasının kendi thumbnail kaydı korundu; genel .pdf kaydı kullanılacak: $path"
                continue
            }
            throw "PDF thumbnail kayıt noktası başka bir CLSID kullanıyor; üzerine yazılmadı: $path"
        }
        $snapshot = Get-KeySnapshot -Root $userRoot -Path $path -Names @('')
        if ($current.Present -and [string]$current.Data -ceq $Clsid) {
            # Bu CLSID bu pakete aittir; yeniden kurulumda kaldırma işlemi yine temizleyebilsin.
            $snapshot = [pscustomobject]@{ Path = $path; KeyExisted = $false; Values = @([pscustomobject]@{ Name = ''; Present = $false; Kind = $null; Data = $null }) }
        }
        $associationSnapshots += [pscustomobject]@{ Path = $path; Snapshot = $snapshot }
    }

    $classPath = "SOFTWARE\Classes\CLSID\$Clsid"
    $inprocPath = "$classPath\InprocServer32"
    $classKey = $machineRoot.OpenSubKey($classPath, $false)
    if ($classKey) {
        $classValues = @($classKey.GetValueNames())
        $classChildren = @($classKey.GetSubKeyNames())
        $classKey.Dispose()
        if ($classValues.Count -ne 0 -or ($classChildren.Count -ne 1) -or $classChildren[0] -cne 'InprocServer32') {
            throw 'Aynı CLSID altında başka COM kayıtları var; üzerine yazılmadı.'
        }
    }
    $existingServer = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name ''
    $existingThread = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name 'ThreadingModel'
    if ($existingServer.Present -and [string]$existingServer.Data -cne $InstalledDll) {
        throw "CLSID başka bir DLL yoluna kayıtlı; üzerine yazılmadı: $($existingServer.Data)"
    }
    if ($existingThread.Present -and [string]$existingThread.Data -cne 'Apartment') {
        throw 'CLSID ThreadingModel değeri beklenenden farklı; üzerine yazılmadı.'
    }
    $comSnapshot = Get-KeySnapshot -Root $machineRoot -Path $inprocPath -Names @('', 'ThreadingModel')
    if ($existingServer.Present -and [string]$existingServer.Data -ceq $InstalledDll -and
        $existingThread.Present -and [string]$existingThread.Data -ceq 'Apartment') {
        $comSnapshot = [pscustomobject]@{
            Path = $inprocPath; KeyExisted = $false
            Values = @(
                [pscustomobject]@{ Name = ''; Present = $false; Kind = $null; Data = $null },
                [pscustomobject]@{ Name = 'ThreadingModel'; Present = $false; Kind = $null; Data = $null }
            )
        }
    }

    New-Item -ItemType Directory -Force -Path $InstallDirectory | Out-Null
    New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
    if (-not (Test-Path -LiteralPath $InstalledDll -PathType Leaf)) {
        Copy-Item -LiteralPath $SourceDll -Destination $InstalledDll
        $copiedDll = $true
    }
    if ((Get-FileHash -LiteralPath $InstalledDll -Algorithm SHA256).Hash -ne $sourceHash) {
        throw 'Kurulum DLL SHA256 doğrulaması başarısız.'
    }

    $state = [ordered]@{
        FormatVersion = 2
        Owner = $Owner
        Installed = $true
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        RegistryView = 'Registry64'
        Clsid = $Clsid
        ThumbnailProviderGuid = $ThumbGuid
        DllPath = $InstalledDll
        DllSha256 = $sourceHash
        ProgIdAtInstall = $progId
        AssociationHive = 'HKEY_CURRENT_USER'
        ComHive = 'HKEY_LOCAL_MACHINE'
        Associations = @($associationSnapshots)
        ComSnapshot = $comSnapshot
    }
    Save-StateFile -State $state
    $stateWritten = $true

    foreach ($item in $associationSnapshots) {
        Set-RegistryString -Root $userRoot -Path $item.Path -Name '' -Value $Clsid
    }
    Set-RegistryString -Root $machineRoot -Path $inprocPath -Name '' -Value $InstalledDll
    Set-RegistryString -Root $machineRoot -Path $inprocPath -Name 'ThreadingModel' -Value 'Apartment'

    $actualServer = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name ''
    $actualThread = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name 'ThreadingModel'
    if (-not $actualServer.Present -or $actualServer.Data -cne $InstalledDll -or
        -not $actualThread.Present -or $actualThread.Data -cne 'Apartment') {
        throw 'COM kaydı doğrulanamadı.'
    }
    foreach ($item in $associationSnapshots) {
        $v = Get-ValueInfo -Root $userRoot -Path $item.Path -Name ''
        if (-not $v.Present -or $v.Data -cne $Clsid) { throw "Thumbnail kaydı doğrulanamadı: $($item.Path)" }
    }

    Notify-Shell
    Write-Host ''
    Write-Host 'PDF KÜÇÜK RESİM SAĞLAYICISI KURULDU' -ForegroundColor Green
    Write-Host "DLL: $InstalledDll"
    Write-Host 'Kurulum varsayılan PDF uygulamasını değiştirmez.'
    Write-Host '.pdf ve SystemFileAssociations kayıtları kullanıldığı için varsayılan PDF uygulaması sonradan değiştirilebilir.'
    Write-Host 'Dosya Gezgini pencerelerini kapatıp yeniden açın.'
}
catch {
    Write-Host ''
    Write-Host ('KURULUM HATASI: ' + $_.Exception.Message) -ForegroundColor Red
    if ($stateWritten -and $null -ne $userRoot -and $null -ne $machineRoot) {
        foreach ($item in $associationSnapshots) {
            try {
                $v = Get-ValueInfo -Root $userRoot -Path $item.Path -Name ''
                if ($v.Present -and $v.Data -ceq $Clsid) {
                    # Geri alma: orijinal varsayılan değeri geri yükle.
                    $prior = $item.Snapshot.Values | Where-Object { $_.Name -ceq '' } | Select-Object -First 1
                    $key = $userRoot.OpenSubKey($item.Path, $true)
                    if ($null -eq $key) { $key = $userRoot.CreateSubKey($item.Path) }
                    if ($prior.Present) { $key.SetValue('', $prior.Data, [Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$prior.Kind)) }
                    else { $key.DeleteValue('', $false) }
                    $key.Dispose()
                }
            } catch { Write-Warning "Geri alma sırasında kayıt korunarak atlandı: $($item.Path)" }
        }
        try {
            $v = Get-ValueInfo -Root $machineRoot -Path $inprocPath -Name ''
            if ($v.Present -and $v.Data -ceq $InstalledDll) {
                $machineRoot.DeleteSubKeyTree($classPath, $false)
            }
        } catch { Write-Warning 'COM kaydı otomatik geri alınamadı; elle değiştirilmedi.' }
    }
    if ($copiedDll -and (Test-Path -LiteralPath $InstalledDll)) {
        try {
            if ((Get-FileHash -LiteralPath $InstalledDll -Algorithm SHA256).Hash -eq $sourceHash) {
                Remove-Item -LiteralPath $InstalledDll -Force
            }
        } catch { Write-Warning 'DLL otomatik geri alınamadı.' }
    }
    if ($stateWritten -and (Test-Path -LiteralPath $StateFile)) {
        Remove-Item -LiteralPath $StateFile -Force -ErrorAction SilentlyContinue
    }
    Read-Host 'Hata oluştu. Ayrıntıları not ettikten sonra Enter tuşuna basın' | Out-Null
    exit 1
}
finally {
    if ($userRoot) { $userRoot.Dispose() }
    if ($machineRoot) { $machineRoot.Dispose() }
}

Read-Host 'Kurulum tamamlandı. Bu pencereyi kapatmak için Enter tuşuna basın' | Out-Null
