@echo off
setlocal
call "%~dp0notion-sync\sync-notion.cmd"
exit /b %ERRORLEVEL%
