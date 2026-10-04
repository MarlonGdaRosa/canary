@echo off
title Iniciar Servidor Canary + Login Server
echo Verificando servico do MariaDB...
sc query CanaryMariaDB | findstr /i "RUNNING" >nul
if %errorlevel% neq 0 (
    echo Iniciando servico CanaryMariaDB...
    net start CanaryMariaDB
)

echo Iniciando Canary e Login-Server...
powershell -ExecutionPolicy Bypass -File "%~dp0.tools\start-local.ps1"
if %errorlevel% equ 0 (
    echo.
    echo ========================================================
    echo  Servidor Canary e Login Server estao ONLINE!
    echo ========================================================
    echo Porta do Jogo: 7172
    echo Webservice Login: http://127.0.0.1:8088/login
    echo.
    echo Agora voce pode abrir o cliente em:
    echo .tools\tibia-client-15.25\bin\client.exe
    echo.
    echo Conta GOD: @god
    echo Senha:     god
    echo ========================================================
) else (
    echo.
    echo Erro ao iniciar o servidor. Verifique os logs em .tools\logs\
)
pause
