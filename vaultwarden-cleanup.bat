@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem ============================================================================
rem vaultwarden-cleanup.bat - Windows launcher for vaultwarden-cleanup.sh
rem Prefers WSL (full Linux bash/jq/.bin/bw support) and falls back to
rem Git Bash / MSYS2 bash.exe if available.
rem
rem Optional environment overrides:
rem   VWC_RUNNER=auto|wsl|bash   Runner selection (default: auto)
rem   VWC_WSL_DISTRO=<name>      Specific WSL distribution name
rem   VWC_BASH_EXE=<path>        Explicit path to a bash.exe executable
rem ============================================================================

set "VWC_RC=0"
set "VWC_WIN_SCRIPT=%~dp0vaultwarden-cleanup.sh"
if not exist "%VWC_WIN_SCRIPT%" (
    echo [ERROR] Script not found: "%VWC_WIN_SCRIPT%" 1>&2
    exit /b 1
)

rem Preserve active console codepage and switch to UTF-8 for box-drawing/icons
set "VWC_ORIG_CP="
for /f "tokens=2 delims=:" %%C in ('chcp 2^>nul') do set "VWC_ORIG_CP=%%C"
if defined VWC_ORIG_CP (
    set "VWC_ORIG_CP=%VWC_ORIG_CP: =%"
    set "VWC_ORIG_CP=%VWC_ORIG_CP:.=%"
)
if not "%VWC_ORIG_CP%"=="65001" chcp 65001 >nul 2>nul

set "VWC_RUNNER_PREF=%VWC_RUNNER%"
if not defined VWC_RUNNER_PREF set "VWC_RUNNER_PREF=auto"

set "VWC_WSL_EXE="
set "VWC_WSL_OK=0"
set "VWC_WSL_JQ=0"

set "VWC_BASH_CANDIDATE="
set "VWC_BASH_OK=0"
set "VWC_BASH_JQ=0"

if /i "%VWC_RUNNER_PREF%"=="auto" goto :mode_auto
if /i "%VWC_RUNNER_PREF%"=="wsl" goto :mode_wsl
if /i "%VWC_RUNNER_PREF%"=="bash" goto :mode_bash

echo [ERROR] Invalid VWC_RUNNER="%VWC_RUNNER_PREF%". Expected: auto, wsl, or bash. 1>&2
set "VWC_RC=1"
goto :cleanup

:mode_auto
call :probe_wsl
if "%VWC_WSL_OK%"=="1" if "%VWC_WSL_JQ%"=="1" goto :run_wsl
call :probe_bash
if "%VWC_BASH_OK%"=="1" if "%VWC_BASH_JQ%"=="1" goto :run_bash
if "%VWC_WSL_OK%"=="1" goto :run_wsl
if "%VWC_BASH_OK%"=="1" goto :run_bash
goto :err_missing_runtime

:mode_wsl
call :probe_wsl
if "%VWC_WSL_OK%"=="1" goto :run_wsl
echo [ERROR] WSL bash is unavailable or no WSL distribution is installed. 1>&2
echo Install WSL with: wsl --install 1>&2
set "VWC_RC=1"
goto :cleanup

:mode_bash
call :probe_bash
if "%VWC_BASH_OK%"=="1" goto :run_bash
echo [ERROR] No standalone Windows bash.exe ^(e.g. Git Bash^) was found. 1>&2
echo Install Git for Windows or set VWC_BASH_EXE=C:\path\to\bash.exe 1>&2
set "VWC_RC=1"
goto :cleanup

:err_missing_runtime
echo [ERROR] Neither WSL ^(wsl.exe^) nor Git Bash ^(bash.exe^) was found. 1>&2
echo. 1>&2
echo Install one of the following: 1>&2
echo   1^) WSL ^(recommended, supports live 'bw' + 'jq'^): wsl --install 1>&2
echo   2^) Git for Windows ^(plus jq^): https://git-scm.com/downloads/win 1>&2
set "VWC_RC=1"
goto :cleanup

:probe_wsl
for /f "delims=" %%W in ('where wsl.exe 2^>nul') do (
    if not defined VWC_WSL_EXE set "VWC_WSL_EXE=%%W"
)
if not defined VWC_WSL_EXE goto :eof
if defined VWC_WSL_DISTRO (
    "%VWC_WSL_EXE%" -d "%VWC_WSL_DISTRO%" -e bash -c "true" >nul 2>nul
) else (
    "%VWC_WSL_EXE%" -e bash -c "true" >nul 2>nul
)
if errorlevel 1 goto :eof
set "VWC_WSL_OK=1"
if defined VWC_WSL_DISTRO (
    "%VWC_WSL_EXE%" -d "%VWC_WSL_DISTRO%" -e bash -c "command -v jq >/dev/null 2>&1" >nul 2>nul
) else (
    "%VWC_WSL_EXE%" -e bash -c "command -v jq >/dev/null 2>&1" >nul 2>nul
)
if not errorlevel 1 set "VWC_WSL_JQ=1"
goto :eof

:probe_bash
if defined VWC_BASH_EXE call :try_bash_path "%VWC_BASH_EXE%"
if "%VWC_BASH_OK%"=="1" if "%VWC_BASH_JQ%"=="1" goto :eof
call :try_bash_path "%ProgramFiles%\Git\bin\bash.exe"
if "%VWC_BASH_OK%"=="1" if "%VWC_BASH_JQ%"=="1" goto :eof
call :try_bash_path "%ProgramFiles(x86)%\Git\bin\bash.exe"
if "%VWC_BASH_OK%"=="1" if "%VWC_BASH_JQ%"=="1" goto :eof
call :try_bash_path "%ProgramW6432%\Git\bin\bash.exe"
if "%VWC_BASH_OK%"=="1" if "%VWC_BASH_JQ%"=="1" goto :eof
call :try_bash_path "%LocalAppData%\Programs\Git\bin\bash.exe"
if "%VWC_BASH_OK%"=="1" if "%VWC_BASH_JQ%"=="1" goto :eof
for /f "delims=" %%G in ('where git.exe 2^>nul') do (
    call :try_bash_path "%%~dpGbash.exe"
    call :try_bash_path "%%~dpG..\bin\bash.exe"
    call :try_bash_path "%%~dpG..\..\bin\bash.exe"
)
for /f "delims=" %%B in ('where bash.exe 2^>nul') do (
    call :is_wsl_bash_shim "%%B"
    if errorlevel 1 call :try_bash_path "%%B"
)
goto :eof

:try_bash_path
if "%~1"=="" goto :eof
if not exist "%~1" goto :eof
call :check_bash_candidate "%~1"
goto :eof

:is_wsl_bash_shim
echo "%~1" | find /i "\System32\bash.exe" >nul && exit /b 0
echo "%~1" | find /i "\SysWOW64\bash.exe" >nul && exit /b 0
echo "%~1" | find /i "\WindowsApps\bash.exe" >nul && exit /b 0
exit /b 1

:check_bash_candidate
if "%VWC_BASH_OK%"=="1" if "%VWC_BASH_JQ%"=="1" goto :eof
"%~1" -c "true" >nul 2>nul
if errorlevel 1 goto :eof
set "_cand_jq=0"
"%~1" -c "command -v jq >/dev/null 2>&1" >nul 2>nul
if not errorlevel 1 set "_cand_jq=1"
if "%VWC_BASH_OK%"=="0" goto :accept_bash_candidate
if "%VWC_BASH_JQ%"=="0" if "%_cand_jq%"=="1" goto :accept_bash_candidate
set "_cand_jq="
goto :eof

:accept_bash_candidate
set "VWC_BASH_CANDIDATE=%~1"
set "VWC_BASH_OK=1"
set "VWC_BASH_JQ=%_cand_jq%"
set "_cand_jq="
goto :eof

:run_wsl
if defined WSLENV (
    set "WSLENV=%WSLENV%:VWC_WIN_SCRIPT/p"
) else (
    set "WSLENV=VWC_WIN_SCRIPT/p"
)
set "VWC_POSIX_SCRIPT="
if defined VWC_WSL_DISTRO (
    for /f "usebackq delims=" %%P in (`call "%VWC_WSL_EXE%" -d "%VWC_WSL_DISTRO%" -e printenv VWC_WIN_SCRIPT 2^>nul`) do set "VWC_POSIX_SCRIPT=%%P"
) else (
    for /f "usebackq delims=" %%P in (`call "%VWC_WSL_EXE%" -e printenv VWC_WIN_SCRIPT 2^>nul`) do set "VWC_POSIX_SCRIPT=%%P"
)
if not defined VWC_POSIX_SCRIPT (
    echo [ERROR] Failed to translate script path into WSL. 1>&2
    set "VWC_RC=1"
    goto :cleanup
)
if defined VWC_WSL_DISTRO (
    "%VWC_WSL_EXE%" -d "%VWC_WSL_DISTRO%" -e bash "%VWC_POSIX_SCRIPT%" %*
) else (
    "%VWC_WSL_EXE%" -e bash "%VWC_POSIX_SCRIPT%" %*
)
set "VWC_RC=%ERRORLEVEL%"
goto :cleanup

:run_bash
"%VWC_BASH_CANDIDATE%" "%VWC_WIN_SCRIPT%" %*
set "VWC_RC=%ERRORLEVEL%"
goto :cleanup

:cleanup
if defined VWC_ORIG_CP (
    if not "%VWC_ORIG_CP%"=="65001" chcp %VWC_ORIG_CP% >nul 2>nul
)
exit /b %VWC_RC%
