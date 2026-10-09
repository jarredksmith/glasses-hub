@echo off
setlocal EnableExtensions
title Glasses Hub setup
cd /d "%~dp0"
echo.
echo   Glasses Hub setup
echo   -----------------
echo.

set "VENV=%LOCALAPPDATA%\GlassesHub\venv"
set "PYVER=3.12.10"
set "PYURL=https://www.python.org/ftp/python/%PYVER%/python-%PYVER%-amd64.exe"
set "PYINST=%TEMP%\python-%PYVER%-amd64.exe"

rem ---- find a usable Python (3.10 to 3.13); install one if there isn't any
call :findpy
if defined PYEXE goto :havepy

echo Python isn't installed on this PC. Installing Python %PYVER% for your account.
echo This needs no admin rights and doesn't change anything for other users.
echo Downloading from python.org (about 25 MB)...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '%PYURL%' -OutFile '%PYINST%'"
if not exist "%PYINST%" goto :pyfail
powershell -NoProfile -Command "if ((Get-AuthenticodeSignature '%PYINST%').Status -ne 'Valid') { exit 1 }"
if errorlevel 1 (
  echo The downloaded installer isn't properly signed, so setup won't run it.
  del "%PYINST%" >nul 2>&1
  goto :pyfail
)
echo Installing Python (about a minute)...
"%PYINST%" /quiet InstallAllUsers=0 PrependPath=0 Include_launcher=0 Include_test=0 Include_doc=0 Shortcuts=0 AssociateFiles=0
del "%PYINST%" >nul 2>&1
call :findpy
if not defined PYEXE goto :pyfail
echo Python installed.
echo.

:havepy
echo Using Python: %PYEXE%
echo.
if not exist "%VENV%\Scripts\python.exe" (
  echo Creating the app environment ^(stored outside OneDrive^)...
  "%PYEXE%" -m venv "%VENV%"
  if errorlevel 1 goto :fail
)
set "VPY=%VENV%\Scripts\python.exe"
echo Installing components (under a minute)...
"%VPY%" -m pip install --upgrade pip --disable-pip-version-check -q
"%VPY%" -m pip install -r requirements.txt --disable-pip-version-check -q
if errorlevel 1 goto :fail

echo Adding a Glasses Hub shortcut to your desktop...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut([Environment]::GetFolderPath('Desktop') + '\Glasses Hub.lnk'); $s.TargetPath='%~dp0Glasses Hub.bat'; $s.WorkingDirectory='%~dp0'; $s.WindowStyle=7; $s.Description='Glasses Hub'; $s.Save()" >nul 2>&1

echo.
echo   Setup finished. Starting Glasses Hub...
echo.
start "" "%VENV%\Scripts\pythonw.exe" "%~dp0hub.py"
timeout /t 3 >nul
exit /b 0

rem ---------------------------------------------------------------------------
:findpy
set "PYEXE="
for %%V in (3.12 3.11 3.13 3.10) do (
  if not defined PYEXE (
    for /f "delims=" %%P in ('py -%%V -c "import sys;print(sys.executable)" 2^>nul') do set "PYEXE=%%P"
  )
)
if defined PYEXE goto :eof
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" (
  set "PYEXE=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
  goto :eof
)
rem skip the Microsoft Store "python" placeholder, which opens the Store instead of running
for /f "delims=" %%P in ('where python 2^>nul ^| findstr /v /i "WindowsApps"') do if not defined PYEXE set "PYEXE=%%P"
if not defined PYEXE goto :eof
"%PYEXE%" -c "import sys;sys.exit(0 if sys.version_info[:2] in [(3,10),(3,11),(3,12),(3,13)] else 1)" >nul 2>&1
if errorlevel 1 set "PYEXE="
goto :eof

:pyfail
echo.
echo   Couldn't install Python automatically.
echo   Install Python 3.12 from https://www.python.org/downloads/ yourself
echo   (tick "Add python.exe to PATH"), then run setup.bat again.
echo   If the download failed, the network may be blocking python.org.
echo.
pause
exit /b 1

:fail
echo.
echo   Setup stopped because of the error above.
echo   If it mentions SSL, certificates or a proxy, the network may be
echo   blocking downloads. Try again on another network or ask IT.
echo.
pause
exit /b 1
