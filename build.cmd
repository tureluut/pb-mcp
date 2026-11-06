@echo off
setlocal
rem ---------------------------------------------------------------------------
rem build.cmd - one-command build for pbmcp.exe (PureBasic 6.40 x64).
rem
rem Usage:  build.cmd         lint + compile pbmcp.exe
rem         build.cmd check   6.40 /CHECK on the real tree (authoritative
rem                           syntax check)
rem
rem Paths are absolute (%~dp0); no shell mangling possible under cmd.exe.
rem MSYS2_ARG_CONV_EXCL additionally guards /SWITCH args when this script is
rem driven from a Git-Bash/MSYS shell; harmless under plain cmd.
rem ---------------------------------------------------------------------------
set "MSYS2_ARG_CONV_EXCL=*"

set "PBC="
if defined PUREBASIC_HOME if exist "%PUREBASIC_HOME%Compilers\pbcompiler.exe" set "PBC=%PUREBASIC_HOME%Compilers\pbcompiler.exe"
if not defined PBC if defined PUREBASIC_HOME if exist "%PUREBASIC_HOME%\Compilers\pbcompiler.exe" set "PBC=%PUREBASIC_HOME%\Compilers\pbcompiler.exe"
if not defined PBC if exist "%LOCALAPPDATA%\Programs\PureBasic\Compilers\pbcompiler.exe" set "PBC=%LOCALAPPDATA%\Programs\PureBasic\Compilers\pbcompiler.exe"
if not defined PBC (
    echo build.cmd: pbcompiler.exe not found - set PUREBASIC_HOME or install PB 6.40 under %%LOCALAPPDATA%%\Programs\PureBasic
    exit /b 1
)

echo build.cmd: encoding lint - UTF-8 BOM required on all src/*.pb
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\lint_encoding.ps1"
if errorlevel 1 (
    echo build.cmd: lint FAILED - fix source encoding before compiling
    exit /b 1
)

set "SRC=%~dp0src\main.pb"
rem PBMCP_OUT overrides the output path (make-dist.cmd builds straight into
rem dist\ so a running server cannot lock the target exe)
if defined PBMCP_OUT (set "OUT=%PBMCP_OUT%") else set "OUT=%~dp0pbmcp.exe"

if /i not "%~1"=="check" goto compile

echo build.cmd: 6.40 /CHECK on "%SRC%"
"%PBC%" /CHECK "%SRC%"
exit /b %errorlevel%

:compile
echo build.cmd: compiling "%SRC%"
"%PBC%" /CONSOLE "%SRC%" /EXE "%OUT%"
if errorlevel 1 (
    echo build.cmd: compile FAILED
    exit /b 1
)
echo build.cmd: OK - "%OUT%"
endlocal
