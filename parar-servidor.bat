@echo off
title Parar Servidor Canary + Login Server
echo Parando Canary e Login-Server...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\local-canaryaac\Stop-LocalCanaryAAC.ps1"
if errorlevel 1 echo AAC nao foi encerrado: identidade nao confirmada. Verifique manualmente.
powershell -ExecutionPolicy Bypass -File "%~dp0.tools\stop-local.ps1"
echo Processos encerrados.
pause
