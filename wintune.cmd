@echo off
rem Lance le menu win-tune. ExecutionPolicy Bypass ne vaut QUE pour ce processus PowerShell :
rem la strategie d'execution de Windows n'est pas modifiee. Pas de droits administrateur requis.
title win-tune
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Start-WinTune.ps1" %*
echo.
pause
