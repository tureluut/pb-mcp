@echo off
setlocal
set "MSYS2_ARG_CONV_EXCL=*"
rem ---------------------------------------------------------------------------
rem make-dist.cmd - build pbmcp.exe and assemble the self-contained dist/
rem
rem Usage:  make-dist.cmd
rem
rem Output layout:
rem   dist\pbmcp.exe
rem   dist\index.json         current docs index (swap for another index-*.json)
rem   dist\README.md
rem   dist\INSTALL.md
rem   dist\skills\purebasic\         complete skill (SKILL.md + references\)
rem
rem Compiles straight into dist\ (via PBMCP_OUT) so a server running from the
rem repo-root exe does not lock the build target. dist\ is gitignored;
rem regenerate after every release-worthy change.
rem ---------------------------------------------------------------------------
cd /d "%~dp0"

echo make-dist: creating dist layout
if exist "dist" rmdir /s /q "dist"
mkdir "dist\skills\purebasic" || goto :fail

echo make-dist: building pbmcp.exe
set "PBMCP_OUT=%~dp0dist\pbmcp.exe"
call build.cmd
if errorlevel 1 (
    echo make-dist: build FAILED - if dist\pbmcp.exe is locked, close the MCP client using it and re-run
    exit /b 1
)

echo make-dist: copying docs + skill
copy /y "README.md"                 "dist\" >nul || goto :fail
copy /y "INSTALL.md"                "dist\" >nul || goto :fail
if exist "src\pbdocs-index.json" copy /y "src\pbdocs-index.json" "dist\index.json" >nul
echo make-dist: copying complete skill tree (SKILL.md + references\)
xcopy /e /i /y "skills\purebasic" "dist\skills\purebasic\" >nul || goto :fail

rem smoke: the artifact must launch (also warms it past first-run AV
rem scanning - a never-executed fresh exe can fail to start in time under
rem the suite's timing-sensitive tests)
echo make-dist: smoke - dist\pbmcp.exe version
"dist\pbmcp.exe" version >nul 2>&1 || goto :fail

echo make-dist: OK
dir /b "dist" "dist\skills\purebasic"
endlocal
exit /b 0

:fail
echo make-dist: assembly FAILED
exit /b 1
