@echo off
rem ===========================================================================
rem  build_windows-x86_64.bat - one-click Windows x86_64 export for 2DBreakout
rem
rem  Usage:
rem    build_windows-x86_64.bat              export release build (default)
rem    build_windows-x86_64.bat debug        export debug build
rem    build_windows-x86_64.bat clean        wipe the build folder, then release
rem    build_windows-x86_64.bat debug-clean  wipe the build folder, then debug
rem    build_windows-x86_64.bat help         show this help
rem
rem  Output: build\windows\2DBreakout.exe  +  2DBreakout.pck
rem          The preset uses binary_format/embed_pck=false, so the .exe and the
rem          .pck must stay in the same folder and be shipped together.
rem
rem  Godot lookup order:
rem    1) GODOT_PATH environment variable
rem    2) godot / godot4 / godot-console on PATH
rem    3) Godot*console*.exe under the project folder, its two parent folders,
rem       %LOCALAPPDATA%\Programs and %USERPROFILE%\Downloads
rem       (console build preferred: its output is directly capturable)
rem
rem  Exit codes: 0 ok / 2 Godot not found / 3 export templates not installed
rem              4 export command failed / 5 artifacts missing
rem
rem  This project is pure GDScript, so any 4.7.2 editor (including the
rem  .NET/Mono build) can export the Windows target. Only Web export
rem  requires the standard editor.
rem
rem  KEEP THIS FILE ASCII-ONLY AND CRLF. cmd.exe reads batch files in blocks
rem  and tracks its position in characters: any non-ASCII byte (GBK or UTF-8
rem  Chinese) desynchronizes that position and corrupts parsing and output.
rem  Chinese documentation for this script lives in README.md.
rem ===========================================================================
setlocal EnableDelayedExpansion

cd /d "%~dp0"

set "PRESET=Windows Desktop"
set "OUT_DIR=build\windows"
set "MODE=release"
set "OUT_FILE=2DBreakout.exe"
set "CLEAN=0"

if /i "%~1"=="help" goto :usage
if /i "%~1"=="-h" goto :usage
if /i "%~1"=="--help" goto :usage
if /i "%~1"=="release" goto :main
if /i "%~1"=="debug" (
	set "MODE=debug"
	set "OUT_FILE=2DBreakout-debug.exe"
) else if /i "%~1"=="clean" (
	set "CLEAN=1"
) else if /i "%~1"=="debug-clean" (
	set "MODE=debug"
	set "OUT_FILE=2DBreakout-debug.exe"
	set "CLEAN=1"
) else if not "%~1"=="" (
	echo Unknown argument: %~1
	goto :usage
)

:main
echo 2DBreakout one-click export - Windows x86_64, %MODE%
echo Project dir: %CD%

if "%CLEAN%"=="1" (
	if exist build (
		rmdir /s /q build
		echo Build folder wiped.
	)
)

rem ---------------------------------------------------------------- 1. find Godot
set "GODOT_EXE="
if defined GODOT_PATH if exist "%GODOT_PATH%" set "GODOT_EXE=%GODOT_PATH%"
if not defined GODOT_EXE (
	for /f "delims=" %%F in ('where godot godot4 godot-console 2^>nul') do (
		if not defined GODOT_EXE set "GODOT_EXE=%%F"
	)
)
if not defined GODOT_EXE call :find_in "%~dp0"
if not defined GODOT_EXE call :find_in "%~dp0.."
if not defined GODOT_EXE call :find_in "%~dp0..\.."
if not defined GODOT_EXE call :find_in "%LOCALAPPDATA%\Programs"
if not defined GODOT_EXE call :find_in "%USERPROFILE%\Downloads"

if not defined GODOT_EXE (
	echo.
	echo Godot executable not found.
	echo Install Godot 4.7, or set GODOT_PATH to the Godot executable, then retry.
	set "RC=2"
	goto :done
)
echo Godot:       %GODOT_EXE%

rem --------------------------------------------------- 2. version and templates
set "VERLINE="
set "VER="
set "SUFFIX="
for /f "delims=" %%V in ('"%GODOT_EXE%" --version 2^>nul') do set "VERLINE=%%V"
for /f "tokens=1,2,3,4 delims=." %%a in ("%VERLINE%") do (
	set "VER=%%a.%%b.%%c"
	set "SUFFIX=%%d"
)
if /i not "%SUFFIX%"=="stable" if /i not "%SUFFIX%"=="dev" if /i not "%SUFFIX%"=="custom" set "SUFFIX="
if defined SUFFIX set "VER=%VER%.%SUFFIX%"

set "TPL_DIR=%APPDATA%\Godot\export_templates\%VER%"
if "%MODE%"=="debug" (set "TPL_NAME=windows_debug_x86_64.exe") else (set "TPL_NAME=windows_release_x86_64.exe")

echo Version:     %VER%
echo Template:    %TPL_DIR%\%TPL_NAME%

if not exist "%TPL_DIR%\%TPL_NAME%" (
	echo.
	echo No Windows x86_64 export template installed for %VER%.
	echo In the Godot editor: Editor -^> Export -^> Export Resources... to install
	echo the %VER% templates, or download the "Export Templates" pack from
	echo https://godotengine.org/download/windows and unpack it into:
	echo     %TPL_DIR%
	echo.
	echo You can also let CI build it: .github\workflows\ci.yml exports all four
	echo platforms and uploads them as build artifacts.
	set "RC=3"
	goto :done
)

rem ------------------------------------------------------------- 3. preset check
findstr /c:"Windows Desktop" export_presets.cfg >nul 2>&1
if errorlevel 1 (
	echo.
	echo export_presets.cfg has no preset named "Windows Desktop".
	set "RC=4"
	goto :done
)

rem -------------------------------------------------- 4. import (needed once)
echo.
echo == 1/2 Import assets ==
"%GODOT_EXE%" --headless --path . --import >nul 2>&1
if not exist ".godot" (
	echo Import failed: no .godot folder was created.
	set "RC=4"
	goto :done
)
echo   OK

rem ------------------------------------------------------------------ 5. export
echo.
echo == 2/2 Export %MODE% build ==
if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"
if not exist "build\.gdignore" echo Godot skips folders that contain .gdignore.> "build\.gdignore"
"%GODOT_EXE%" --headless --path . --export-%MODE% "%PRESET%" "%OUT_DIR%\%OUT_FILE%"
set "RC=%errorlevel%"
if not "%RC%"=="0" (
	echo.
	echo The export command returned %RC%. See the Godot output above.
	set "RC=4"
	goto :done
)

rem -------------------------------------------------------------- 6. artifacts
set "EXE=%OUT_DIR%\%OUT_FILE%"
set "PCK=%OUT_DIR%\%OUT_FILE:~0,-4%.pck"
if not exist "%EXE%" (
	echo.
	echo The export command reported success but %EXE% was not created.
	set "RC=5"
	goto :done
)
if not exist "%PCK%" (
	echo.
	echo Data pack %PCK% is missing. The preset does not embed the pck, so the
	echo exe and the pck must be shipped together.
	set "RC=5"
	goto :done
)

for %%F in ("%EXE%") do set "EXE_SIZE=%%~zF"
for %%F in ("%PCK%") do set "PCK_SIZE=%%~zF"

echo.
echo Export finished:
echo   %EXE%  ^(%EXE_SIZE% bytes^)
echo   %PCK%  ^(%PCK_SIZE% bytes^)
echo Double-click the exe to play. Ship the exe and the pck in the same folder.
set "RC=0"
goto :done

rem ---------------------------------------------------------------- subroutines
:find_in
if defined GODOT_EXE goto :eof
for %%D in ("%~f1") do set "BASE=%%~fD"
if not exist "%BASE%\" goto :eof
for /f "delims=" %%F in ('dir /b /s /a-d "%BASE%\Godot*console*.exe" 2^>nul') do if not defined GODOT_EXE set "GODOT_EXE=%%F"
if defined GODOT_EXE goto :eof
for /f "delims=" %%F in ('dir /b /s /a-d "%BASE%\Godot*.exe" 2^>nul') do if not defined GODOT_EXE set "GODOT_EXE=%%F"
goto :eof

:usage
echo.
echo Usage: build_windows-x86_64.bat [release ^| debug ^| clean ^| debug-clean ^| help]
echo.
echo   release       default, writes build\windows\2DBreakout.exe
echo   debug         writes build\windows\2DBreakout-debug.exe, with debug info
echo   clean         deletes the build folder, then exports the release build
echo   debug-clean   deletes the build folder, then exports the debug build
echo.
echo Requires the Windows export templates of the same version as the editor:
echo   %APPDATA%\Godot\export_templates\^<version^>\windows_release_x86_64.exe
echo Exit codes: 0 ok / 2 Godot not found / 3 templates not installed /
echo             4 export failed / 5 artifacts missing
set "RC=0"
goto :done

:done
exit /b %RC%
