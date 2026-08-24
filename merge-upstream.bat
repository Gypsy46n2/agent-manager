@echo off
rem Merge the fetched upstream (Linux repo) changes into your Windows fork
cd /d "%~dp0"
git merge upstream/master
echo.
echo If the merge succeeded, run push-fork.bat to publish it to your fork.
pause
