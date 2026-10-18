@echo off
setlocal
chcp 65001 >nul
title SLATE - push to GitHub
cd /d "%~dp0"

echo.
echo   ==================================================
echo    SLATE  -  push source to GitHub
echo   ==================================================
echo.

rem ---------- locate git ----------
rem WorkBuddy bundles a PortableGit; add BOTH cmd and mingw64\bin
rem (credential manager lives in mingw64\bin, not in cmd)

set "PG=%LOCALAPPDATA%\Programs\WorkBuddy\resources\vendor\PortableGit"
if exist "%PG%\cmd\git.exe" set "PATH=%PG%\mingw64\bin;%PG%\cmd;%PATH%"

if exist "%ProgramFiles%\Git\cmd\git.exe" set "PATH=%ProgramFiles%\Git\mingw64\bin;%ProgramFiles%\Git\cmd;%PATH%"

if exist "%ProgramFiles(x86)%\Git\cmd\git.exe" set "PATH=%ProgramFiles(x86)%\Git\mingw64\bin;%ProgramFiles(x86)%\Git\cmd;%PATH%"

where git >nul 2>nul
if errorlevel 1 goto NO_GIT

rem ---------- repo url ----------
rem default repo; pass a different url as first argument to override

set "REPO=%~1"
if not "%REPO%"=="" goto HAVE_REPO
set "REPO=https://github.com/hualianl638-svg/slate-ios.git"
:HAVE_REPO

echo   Repo:
echo     %REPO%
echo.

rem ---------- git init ----------
if exist ".git" goto HAS_GIT
echo   [1/4] git init
git init -q
if errorlevel 1 goto FAIL
:HAS_GIT

rem ---------- stage + commit ----------
echo   [2/4] stage files
git add -A
if errorlevel 1 goto FAIL

echo   [3/4] commit
git -c user.name="SLATE" -c user.email="dev@slate.app" commit -q -m "M1: cloud-built iOS app - import and probe"
if errorlevel 1 echo         (nothing changed - ok)

git branch -M main

rem ---------- remote ----------
echo   [4/4] remote + push
git remote remove origin >nul 2>nul
git remote add origin "%REPO%"
if errorlevel 1 goto FAIL

echo.
echo   ------------------------------------------------
echo    A browser window may open for GitHub sign-in.
echo    Sign in once, then come back to this window.
echo   ------------------------------------------------
echo.

rem credential manager must be reachable, otherwise git will ask
rem for a username/password on the console and confuse the user

where git-credential-manager >nul 2>nul
if errorlevel 1 goto NO_GCM

git config --local credential.helper manager
goto PUSH

:NO_GCM
git config --local --unset credential.helper >nul 2>nul

:PUSH
git push -u origin main
if not errorlevel 1 goto OK

echo.
echo   First push was rejected. Retrying after sync...
git pull --rebase --allow-unrelated-histories origin main
git push -u origin main
if not errorlevel 1 goto OK

echo.
echo   --------------------------------------------------
echo    PUSH FAILED.
echo.
echo    Try one of these:
echo      1. Repo already has a README from GitHub, then run:
echo             git push -u origin main --force
echo      2. Sign-in window never appeared, then create a token:
echo             github.com - Settings - Developer settings
echo             - Personal access tokens - Tokens (classic)
echo             scope: repo
echo         and run:
echo             git remote set-url origin https://TOKEN@github.com/hualianl638-svg/slate-ios.git
echo             git push -u origin main
echo      3. Wrong URL - check the repo page on github.com
echo   --------------------------------------------------
goto END

:OK
echo.
echo   ==================================================
echo    Pushed.
echo    Open the Actions tab, the build starts by itself:
echo    %REPO%/actions
echo   ==================================================
goto END

:NO_GIT
echo   git not found.
echo   Install Git for Windows: https://git-scm.com/download/win
goto END

:FAIL
echo.
echo   A git command failed. Scroll up for the error message.

:END
echo.
pause
exit /b
