@echo off
title Parar Servidor Canary + Login Server
echo Parando Canary e Login-Server...
powershell -ExecutionPolicy Bypass -File "%~dp0.tools\stop-local.ps1"
echo Processos encerrados.
pause
