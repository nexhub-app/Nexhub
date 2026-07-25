@echo off
setlocal

REM NexHub helper: install Flutter 3.32.0 stable from the official zip.
REM Double-click to run. Edit FLUTTER_ROOT to change install location.
REM Avoids the old git-based install which can corrupt internal files.

set "FLUTTER_ROOT=E:/flutter"
set "DOWNLOAD_URL=https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.32.0-stable.zip"

echo ============================================
echo   NexHub: install Flutter 3.32.0 stable
echo ============================================
echo.

if exist "%FLUTTER_ROOT%\bin\flutter.bat" (
    echo [INFO] Flutter already exists at %FLUTTER_ROOT%
    echo To reinstall, delete that folder first, then run again.
    pause
    exit /b 0
)

echo [1/3] Downloading Flutter 3.32.0 stable...
echo URL: %DOWNLOAD_URL%
echo This is about 1.7 GB. Please wait, it can take several minutes.
curl.exe -L -o "%TEMP%\flutter_332.zip" "%DOWNLOAD_URL%"
if errorlevel 1 (
    echo [ERROR] Download failed. Check network or VPN and retry.
    pause
    exit /b 1
)

echo [2/3] Extracting archive...
tar.exe -xf "%TEMP%\flutter_332.zip" -C "%TEMP%\flutter_extract"
if errorlevel 1 (
    echo [ERROR] Extraction failed.
    pause
    exit /b 1
)

if not exist "%TEMP%\flutter_extract\flutter\bin\flutter.bat" (
    echo [ERROR] Extracted archive missing flutter\bin\flutter.bat
    pause
    exit /b 1
)

echo [3/3] Moving to %FLUTTER_ROOT%...
if exist "%FLUTTER_ROOT%" (
    rmdir /s /q "%FLUTTER_ROOT%"
)
move "%TEMP%\flutter_extract\flutter" "%FLUTTER_ROOT%"
if errorlevel 1 (
    echo [ERROR] Move failed. Try running this script as administrator.
    pause
    exit /b 1
)

del /f "%TEMP%\flutter_332.zip" >nul 2>&1
rmdir /s /q "%TEMP%\flutter_extract" >nul 2>&1

echo.
echo ============================================
echo   DONE. Flutter 3.32.0 stable installed at
echo   %FLUTTER_ROOT%
echo   Verify with: %FLUTTER_ROOT%\bin\flutter.bat --version
echo ============================================
pause
