@echo off
setlocal
set "SCRIPT=%~dp0Install.ps1"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "$argList='-NoProfile -ExecutionPolicy Bypass -File '+[char]34+$env:SCRIPT+[char]34; $p=Start-Process -FilePath $env:PSEXE -Verb RunAs -ArgumentList $argList -PassThru -Wait; exit $p.ExitCode"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Kurulum tamamlanamadi. Yukaridaki hata iletisini kontrol edin.
  pause
)
exit /b %RC%
