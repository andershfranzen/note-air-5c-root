@echo off
setlocal
title BOOX Note Air 5C Root Assistant
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-NoteAir5C.ps1" %*
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-NoteAir5C.ps1" %*
)
if not %errorlevel%==0 (
  echo.
  echo The assistant stopped with an error. Review the message above.
  pause
)
endlocal
