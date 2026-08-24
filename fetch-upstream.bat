@echo off
rem Fetch the latest changes from the original Linux repo (upstream)
cd /d "%~dp0"
git fetch upstream
echo.
echo Fetched upstream. New commits not yet merged into your branch:
git log --oneline master..upstream/master
pause
