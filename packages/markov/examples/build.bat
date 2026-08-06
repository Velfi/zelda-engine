@echo off
setlocal
REM DUMBAI: Resolve helper directory so this script works from any current working directory.
set "SCRIPT_DIR=%~dp0"

REM DUMBAI: Prefer local build.py when present so build.bat args drive the folder build script.
if exist "%SCRIPT_DIR%build.py" (
    python "%SCRIPT_DIR%build.py" %*
    exit /b %errorlevel%
)

REM DUMBAI: Fallback keeps helper generic in folders without build.py.
python %*