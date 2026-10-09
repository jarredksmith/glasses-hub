@echo off
set "VENV=%LOCALAPPDATA%\GlassesHub\venv"
if not exist "%VENV%\Scripts\pythonw.exe" (
  call "%~dp0setup.bat"
  exit /b
)
"%VENV%\Scripts\python.exe" -c "import cryptography" >nul 2>&1 || (
  echo Installing an update for Glasses Hub...
  "%VENV%\Scripts\python.exe" -m pip install -r "%~dp0requirements.txt" --disable-pip-version-check -q
)
start "" "%VENV%\Scripts\pythonw.exe" "%~dp0hub.py" %*
