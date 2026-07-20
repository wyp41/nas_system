@echo off
setlocal
set "MOUNT_SCRIPT=%LOCALAPPDATA%\Programs\rclone-nas\Nas-Mount.ps1"
if not exist "%MOUNT_SCRIPT%" (
    echo NAS mount is not installed. Run install-windows.cmd first.
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%MOUNT_SCRIPT%" %*
exit /b %ERRORLEVEL%
