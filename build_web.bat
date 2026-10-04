@echo off
rem ===========================================================================
rem  build_web.bat - one-click HTML5 (Web) export for 2DBreakout
rem
rem  Usage:
rem    build_web.bat              export release build (default)
rem    build_web.bat debug        export debug build
rem    build_web.bat clean        wipe the build folder, then release
rem    build_web.bat debug-clean  wipe the build folder, then debug
rem    build_web.bat serve        export, then serve the folder on http://...
rem    build_web.bat help         show this help
rem
rem  Output: build\web\index.html  +  index.js  +  index.wasm  +  index.pck
rem          plus index.audio.worklet.js and the html icons. Ship the whole
rem          folder, keep the file names, they reference each other.
rem
rem  IMPORTANT: you cannot play a Web build by double-clicking index.html.
rem  Browsers refuse the .js / .wasm / .pck requests on a file:// page. The
rem  folder must be served over http:// - this script can do it for you:
rem      build_web.bat serve        then open http://127.0.0.1:8000
rem
rem  Godot lookup order (same as build_windows-x86_64.bat, plus one rule):
rem    1) GODOT_PATH environment variable
rem    2) godot / godot4 / godot-console on PATH
rem    3) Godot*console*.exe under the project folder, its two parent folders,
rem       %LOCALAPPDATA%\Programs and %USERPROFILE%\Downloads
rem       (console build preferred: its output is directly capturable)
rem    Auto-discovered candidates whose path contains "mono" are SKIPPED: the
rem    .NET/Mono editor cannot export Web at all. If GODOT_PATH points at a
rem    Mono editor the script stops and says so (exit code 6).
rem
rem  Exit codes: 0 ok / 2 Godot not found / 3 export templates not installed
rem              4 export command failed / 5 artifacts missing
rem              6 Mono editor, cannot export Web
rem
rem  This project is pure GDScript. Web export needs the STANDARD editor of
rem  the matching version, plus the web templates in:
rem    %APPDATA%\Godot\export_templates\<version>\web_nothreads_release.zip
rem
rem  KEEP THIS FILE ASCII-ONLY AND CRLF. cmd.exe reads batch files in blocks
rem  and tracks its position in characters: any non-ASCII byte (GBK or UTF-8
rem  Chinese) desynchronizes that position and corrupts parsing and output.
rem  Chinese documentation for this script lives in README.md.
rem ===========================================================================
setlocal EnableDelayedExpansion

cd /d "%~dp0"

set "PRESET=Web"
set "OUT_DIR=build\web"
set "OUT_FILE=index.html"
set "MODE=release"
set "CLEAN=0"
set "SERVE=0"

if /i "%~1"=="help" goto :usage
if /i "%~1"=="-h" goto :usage
if /i "%~1"=="--help" goto :usage
if /i "%~1"=="release" goto :main
if /i "%~1"=="debug" (
	set "MODE=debug"
) else if /i "%~1"=="clean" (
	set "CLEAN=1"
) else if /i "%~1"=="debug-clean" (
	set "MODE=debug"
	set "CLEAN=1"
) else if /i "%~1"=="serve" (
	set "SERVE=1"
) else if not "%~1"=="" (
	echo Unknown argument: %~1
	goto :usage
)

:main
echo 2DBreakout one-click export - Web HTML5, %MODE%
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
	for /f "delims=" %%F in ('where godot godot4 godot-console 2^>nul ^| findstr /i /v "mono"') do (
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

rem The .NET/Mono editor refuses Web export, so stop early with a clear reason.
echo %VERLINE%| findstr /i /c:".mono." >nul 2>&1
if not errorlevel 1 (
	echo.
	echo This is the .NET/Mono editor: it cannot export the Web platform.
	echo Use the standard editor instead, for example:
	echo     set GODOT_PATH=C:\path\to\Godot_v4.7.2-stable_win64_console.exe
	echo The version line was: %VERLINE%
	set "RC=6"
	goto :done
)

rem Which web template the preset needs depends on the preset's own switches.
set "TPL_KIND=web_nothreads"
findstr /c:"variant/extensions_support=true" export_presets.cfg >nul 2>&1
if not errorlevel 1 set "TPL_KIND=web_dlink"
findstr /c:"variant/thread_support=true" export_presets.cfg >nul 2>&1
if not errorlevel 1 set "TPL_KIND=web"
set "TPL_NAME=%TPL_KIND%_%MODE%.zip"
set "TPL_DIR=%APPDATA%\Godot\export_templates\%VER%"

echo Version:     %VER%
echo Template:    %TPL_DIR%\%TPL_NAME%

if not exist "%TPL_DIR%\%TPL_NAME%" (
	echo.
	echo No Web %MODE% export template installed for %VER%.
	echo In the Godot editor: Editor -^> Export -^> Export Resources... to install
	echo the %VER% templates, or download the "Export Templates" pack from
	echo https://godotengine.org/download/windows and unpack it into:
	echo     %TPL_DIR%
	echo.
	echo You can also let CI build it: .github\workflows\deploy-web.yml exports
	echo the Web build and publishes it to GitHub Pages.
	set "RC=3"
	goto :done
)

rem ------------------------------------------------------------- 3. preset check
rem findstr has no end-of-line anchor, so "^name=.Web." (dot = the quote char)
rem is the exact-match form: it hits name="Web" and skips name="Windows Desktop".
findstr /r /c:"^name=.Web." export_presets.cfg >nul 2>&1
if errorlevel 1 (
	echo.
	echo export_presets.cfg has no preset named exactly "Web".
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
rem These four reference each other by name; a Web build is incomplete without
rem any one of them, and browsers only load them over http://, never file://.
set "MISSING="
for %%E in (.html .js .wasm .pck) do (
	if not exist "%OUT_DIR%\index%%E" set "MISSING=!MISSING! index%%E"
)
if not "!MISSING!"=="" (
	echo.
	echo The export command reported success but these files are missing:!MISSING!
	set "RC=5"
	goto :done
)

rem Godot imports every png it finds inside the project folder, so the html
rem icons exported into build\web come with .import sidecars. They are not part
rem of the build; drop them so the folder you ship or publish stays clean.
del /q "%OUT_DIR%\*.import" >nul 2>&1

echo.
echo Export finished:
for %%F in ("%OUT_DIR%\index.*") do echo   %%~nxF  %%~zF bytes
echo.
echo Files to ship: the whole %OUT_DIR% folder, names unchanged.
set "RC=0"
if "%SERVE%"=="0" goto :serve_hint
goto :serve

:serve_hint
echo Open it with a static HTTP server, never by double-clicking index.html:
echo     cd %OUT_DIR% ^&^& python -m http.server 8000
echo Or just run: build_web.bat serve
goto :done

rem ------------------------------------------------------------------- serve
:serve
set "PY="
where python >nul 2>&1
if not errorlevel 1 set "PY=python"
if not defined PY (
	where py >nul 2>&1
	if not errorlevel 1 set "PY=py"
)
if not defined PY (
	echo.
	echo Python was not found, so the local server cannot be started.
	echo Serve %OUT_DIR% with any static HTTP server, for example:
	echo     cd %OUT_DIR% ^&^& python -m http.server 8000
	set "RC=0"
	goto :done
)
echo.
echo Serving %OUT_DIR% at http://127.0.0.1:8000  -  press Ctrl+C to stop.
cd "%OUT_DIR%"
"%PY%" -m http.server 8000
goto :done

rem ---------------------------------------------------------------- subroutines
:find_in
if defined GODOT_EXE goto :eof
for %%D in ("%~f1") do set "BASE=%%~fD"
if not exist "%BASE%\" goto :eof
for /f "delims=" %%F in ('dir /b /s /a-d "%BASE%\Godot*console*.exe" 2^>nul ^| findstr /i /v "mono"') do if not defined GODOT_EXE set "GODOT_EXE=%%F"
if defined GODOT_EXE goto :eof
for /f "delims=" %%F in ('dir /b /s /a-d "%BASE%\Godot*.exe" 2^>nul ^| findstr /i /v "mono"') do if not defined GODOT_EXE set "GODOT_EXE=%%F"
goto :eof

:usage
echo.
echo Usage: build_web.bat [release ^| debug ^| clean ^| debug-clean ^| serve ^| help]
echo.
echo   release       default, writes build\web\index.html and its data files
echo   debug         same files, with the debug web template (larger, slower)
echo   clean         deletes the build folder, then exports the release build
echo   debug-clean   deletes the build folder, then exports the debug build
echo   serve         exports the release build, then serves it on port 8000
echo.
echo A Web build must be served over http://. Double-clicking index.html does
echo not work: browsers block the .js / .wasm / .pck requests on file:// pages.
echo.
echo Requires the standard editor (NOT the .NET/Mono build) and the Web export
echo templates of the same version as the editor:
echo   %APPDATA%\Godot\export_templates\^<version^>\web_nothreads_release.zip
echo The preset disables thread support, so the build needs no COOP/COEP
echo response headers and runs on GitHub Pages, itch.io, Netlify, S3, nginx.
echo Exit codes: 0 ok / 2 Godot not found / 3 templates not installed /
echo             4 export failed / 5 artifacts missing / 6 Mono editor
set "RC=0"
goto :done

:done
exit /b %RC%
