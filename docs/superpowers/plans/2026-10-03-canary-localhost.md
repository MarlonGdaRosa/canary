# Canary Localhost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compile this Canary checkout and provide a verified localhost Tibia 15.25 environment where `@god` / `god` can enter the world as `GOD`.

**Architecture:** Build Canary natively with the repository's MSVC/Ninja/vcpkg preset, run a dedicated local MariaDB instance, and build OpenTibiaBR's Go login-server against the same database. A checksum-verified Tibia 15.25 client is configured for the local HTTP login endpoint and driven through a real GOD login while Canary and database state provide end-to-end evidence.

**Tech Stack:** C++23, CMake, Ninja, MSVC v145, vcpkg, MariaDB 11.8.5, Go, OpenTibiaBR login-server, Tibia 15.25 Windows client, PowerShell.

**Spec:** `docs/superpowers/specs/2026-10-03-canary-localhost-design.md`

## Global Constraints

- Work only on branch `codex/canary-localhost-setup`, never `main`.
- Follow `AGENTS.md` and `docs/building/local-validation.md` for every Canary configure/build.
- Use the maintained `windows-release` preset and its `v145` toolset contract.
- Keep downloads, runtime scripts, database files, and client files under ignored `.tools/`; keep the map and `config.lua` in their already ignored paths.
- Bind MariaDB, login-server, and Canary to localhost; do not create firewall exposure.
- Do not replace the required source builds with downloaded Canary or login-server binaries.
- Use the schema-provided credentials exactly: login `@god`, password `god`, character `GOD`, group `6`.
- Treat `build/windows-release` as the only permitted CMake cache for this build.

---

### Task 1: Complete and verify the native Windows toolchain

**Files:**
- Inspect: `CMakePresets.json`
- Inspect: `docs/building/local-validation.md`
- No repository files are modified.

**Interfaces:**
- Consumes: Windows package manager and the existing Visual Studio 2022 installation.
- Produces: Visual Studio Community 2026 with MSVC v145, ATL, CMake tools, English resources, and a Windows 11 SDK.

- [ ] **Step 1: Run the failing v145 preflight**

```powershell
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vsRoot = & $vswhere -latest -products * -version '[18.0,19.0)' -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath
if (-not $vsRoot) { throw 'Visual Studio 2026 Native Desktop workload is missing' }
$cl = Get-ChildItem "$vsRoot\VC\Tools\MSVC\14.5*\bin\Hostx64\x64\cl.exe" -ErrorAction Stop | Select-Object -First 1
$atl = Get-ChildItem "$vsRoot\VC\Tools\MSVC\14.5*\atlmfc\include\atlbase.h" -ErrorAction Stop | Select-Object -First 1
```

Expected on the initial machine: FAIL because only Visual Studio 2022 is installed.

- [ ] **Step 2: Install Visual Studio Community 2026 components**

```powershell
winget install --exact --id Microsoft.VisualStudio.Community --accept-package-agreements --accept-source-agreements --override '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --add Microsoft.VisualStudio.Component.VC.ATL --add Microsoft.VisualStudio.Component.VC.CMake.Project --add Microsoft.VisualStudio.Component.Windows11SDK.26100 --addProductLang en-US'
```

If the installer reports that a reboot is required, rerun the preflight first. A
restart is required only when the new `cl.exe` cannot execute in `VsDevCmd.bat`.

- [ ] **Step 3: Verify the installed toolchain in a developer shell**

```powershell
$vsRoot = & $vswhere -latest -products * -version '[18.0,19.0)' -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath
cmd /d /s /c "`"$vsRoot\Common7\Tools\VsDevCmd.bat`" -arch=x64 -host_arch=x64 && where cl && cl 2>&1 | findstr /C:`"Compiler Version`" && where cmake && where ninja"
```

Expected: all paths resolve under the VS 2026 installation and the compiler
reports a 19.5x version.

---

### Task 2: Bootstrap vcpkg and compile Canary Release

**Files:**
- Create: `.tools/vcpkg/` (ignored clone)
- Create: `.tools/build-canary.cmd` (ignored helper)
- Produce: `build/windows-release/` (ignored CMake tree)
- Produce: `canary.exe` (ignored compiled executable)

**Interfaces:**
- Consumes: the verified Task 1 developer toolchain and `CMakePresets.json`.
- Produces: a Release Canary executable compiled from the current commit.

- [ ] **Step 1: Confirm the expected missing vcpkg state**

```powershell
if (Test-Path '.tools\vcpkg\vcpkg.exe') { throw 'Unexpected pre-existing project vcpkg; audit it before continuing' }
```

Expected initially: the command exits without output because vcpkg is absent.

- [ ] **Step 2: Clone and bootstrap project-managed vcpkg**

```powershell
New-Item -ItemType Directory -Force '.tools' | Out-Null
git clone https://github.com/microsoft/vcpkg.git .tools/vcpkg
& '.tools\vcpkg\bootstrap-vcpkg.bat' -disableMetrics
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& '.tools\vcpkg\vcpkg.exe' version
```

- [ ] **Step 3: Create the single-shell build helper**

Create `.tools/build-canary.cmd` with `apply_patch` using this exact content:

```bat
@echo off
setlocal
set "VSWHERE=C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -version [18.0^,19.0^) -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath`) do set "VSROOT=%%I"
if not defined VSROOT exit /b 10
call "%VSROOT%\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64
if errorlevel 1 exit /b %errorlevel%
set "VCPKG_ROOT=C:\Users\Marlon\Documents\OT\.tools\vcpkg"
if not exist "%VCPKG_ROOT%\vcpkg.exe" exit /b 11
if not exist "%VCPKG_ROOT%\scripts\buildsystems\vcpkg.cmake" exit /b 12
where ninja >nul 2>&1 || set "PATH=%VSROOT%\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"
where cl || exit /b 13
where ninja || exit /b 14
cmake --preset windows-release
if errorlevel 1 exit /b %errorlevel%
cmake --build --preset windows-release --target canary
exit /b %errorlevel%
```

- [ ] **Step 4: Configure and build with the maintained preset**

```powershell
& '.tools\build-canary.cmd'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

If cache recovery is required, first prove the failing cache is exactly
`build/windows-release`, stop every CMake/Ninja process, remove only that preset
directory, and rerun the same helper.

- [ ] **Step 5: Verify the compiled artifact belongs to this build**

```powershell
$exe = Get-Item '.\canary.exe' -ErrorAction Stop
if ($exe.LastWriteTime -lt (Get-Date).AddHours(-2)) { throw 'canary.exe is not from the current build window' }
Get-FileHash $exe.FullName -Algorithm SHA256
git rev-parse HEAD
```

Expected: `canary.exe` exists at the repository root, has a fresh timestamp, and
has a recorded SHA-256 alongside the source commit.

---

### Task 3: Provision the dedicated MariaDB service and schema

**Files:**
- Create: `.tools/downloads/mariadb-11.8.5-winx64.zip`
- Create: `.tools/mariadb/`
- Create: `.tools/mariadb-data/`
- Read: `schema.sql`

**Interfaces:**
- Consumes: the upstream Canary schema.
- Produces: localhost MariaDB service `CanaryMariaDB`, database `canary`, user `canary`, and seeded GOD data.

- [ ] **Step 1: Verify port and service names are unused**

```powershell
if (Get-Service -Name CanaryMariaDB -ErrorAction SilentlyContinue) { throw 'CanaryMariaDB already exists; inspect it before provisioning' }
if (Get-NetTCPConnection -LocalPort 3306 -State Listen -ErrorAction SilentlyContinue) { throw 'TCP 3306 is already occupied' }
```

Expected initially: no service and no listener.

- [ ] **Step 2: Download and verify MariaDB 11.8.5 x64**

```powershell
New-Item -ItemType Directory -Force '.tools\downloads' | Out-Null
$archive = Resolve-Path '.tools\downloads' | ForEach-Object { Join-Path $_ 'mariadb-11.8.5-winx64.zip' }
Invoke-WebRequest 'https://downloads.mariadb.org/rest-api/mariadb/11.8.5/mariadb-11.8.5-winx64.zip' -OutFile $archive
$actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne '75332dc1f437d9ecee253c2d751d02a69628b109ddd031006f8a8d9ba59dbe0d') { throw "MariaDB checksum mismatch: $actual" }
```

- [ ] **Step 3: Extract the portable server**

```powershell
Expand-Archive '.tools\downloads\mariadb-11.8.5-winx64.zip' '.tools\mariadb-unpack' -Force
Move-Item -LiteralPath '.tools\mariadb-unpack\mariadb-11.8.5-winx64' -Destination '.tools\mariadb'
Remove-Item -LiteralPath '.tools\mariadb-unpack' -Force
```

- [ ] **Step 4: Register and start a localhost-only Windows service**

Run the registration elevated because Windows service creation requires it:

```powershell
$installer = (Resolve-Path '.tools\mariadb\bin\mariadb-install-db.exe').Path
$data = Join-Path (Resolve-Path '.tools').Path 'mariadb-data'
$args = "--datadir=`"$data`" --service=CanaryMariaDB --password=root --port=3306"
$p = Start-Process -FilePath $installer -ArgumentList $args -Verb RunAs -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -ne 0) { throw "mariadb-install-db failed with $($p.ExitCode)" }
$p = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-Command','Start-Service -Name CanaryMariaDB' -Verb RunAs -Wait -PassThru -WindowStyle Hidden
if ($p.ExitCode -ne 0) { throw "CanaryMariaDB start failed with $($p.ExitCode)" }
```

- [ ] **Step 5: Wait on database readiness without a fixed sleep**

```powershell
$db = (Resolve-Path '.tools\mariadb\bin\mariadb.exe').Path
$deadline = (Get-Date).AddSeconds(60)
do {
  & $db --protocol=tcp -h127.0.0.1 -P3306 -uroot -proot -e 'SELECT 1' 2>$null
  if ($LASTEXITCODE -eq 0) { break }
  Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
if ($LASTEXITCODE -ne 0) { throw 'MariaDB did not become ready in 60 seconds' }
```

- [ ] **Step 6: Create the application database/user and import the schema**

```powershell
& $db --protocol=tcp -h127.0.0.1 -P3306 -uroot -proot -e "CREATE DATABASE canary CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; CREATE USER 'canary'@'127.0.0.1' IDENTIFIED BY 'canary'; GRANT ALL PRIVILEGES ON canary.* TO 'canary'@'127.0.0.1'; FLUSH PRIVILEGES;"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $db --protocol=tcp -h127.0.0.1 -P3306 -uroot -proot canary -e "SOURCE C:/Users/Marlon/Documents/OT/schema.sql"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

- [ ] **Step 7: Verify schema and GOD records without exposing the password hash**

```powershell
& $db --protocol=tcp -h127.0.0.1 -P3306 -ucanary -pcanary canary --batch --skip-column-names -e "SELECT value FROM server_config WHERE config='db_version'; SELECT email,type FROM accounts WHERE id=1; SELECT name,group_id FROM players WHERE id=7;"
```

Expected rows: schema version `59`, `@god  6`, and `GOD  6`.

---

### Task 4: Configure Canary runtime data and localhost settings

**Files:**
- Create: `config.lua` (ignored runtime copy of `config.lua.dist`)
- Create: `data-otservbr-global/world/otservbr.otbm` (ignored release map)

**Interfaces:**
- Consumes: the Task 2 executable and Task 3 database.
- Produces: a runnable Canary configuration rooted at this checkout.

- [ ] **Step 1: Prove required runtime files are initially missing**

```powershell
if (Test-Path 'config.lua') { throw 'Unexpected config.lua; audit it before overwriting' }
if (Test-Path 'data-otservbr-global\world\otservbr.otbm') { throw 'Unexpected map; audit it before downloading' }
```

- [ ] **Step 2: Download and verify the upstream global map**

```powershell
$map = 'data-otservbr-global\world\otservbr.otbm'
Invoke-WebRequest 'https://github.com/opentibiabr/canary/releases/download/v3.6.1/otservbr.otbm' -OutFile $map
$actual = (Get-FileHash $map -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne 'a80de1dda6a9aca3956a9d5b7fb2e0caebb451570d26853fc21beb40d5f31da2') { throw "Map checksum mismatch: $actual" }
```

- [ ] **Step 3: Create the ignored runtime config and apply only local overrides**

```powershell
Copy-Item -LiteralPath 'config.lua.dist' -Destination 'config.lua'
```

Then use `apply_patch` on `config.lua` with this exact patch:

```diff
*** Begin Patch
*** Update File: C:\Users\Marlon\Documents\OT\config.lua
@@
-serverName = "OTServBR-Global"
+serverName = "OpenTibiaBR Canary Local"
@@
-mysqlUser = "root"
-mysqlPass = "root"
-mysqlDatabase = "otservbr-global"
+mysqlUser = "canary"
+mysqlPass = "canary"
+mysqlDatabase = "canary"
*** End Patch
```

- [ ] **Step 4: Verify the effective localhost contract**

```powershell
rg -n '^(dataPackDirectory|ip|loginProtocolPort|gameProtocolPort|statusProtocolPort|serverName|mapName|mysqlHost|mysqlUser|mysqlPass|mysqlDatabase|passwordType|authType)' config.lua
```

Expected: datapack `data-otservbr-global`, IP `127.0.0.1`, login/status 7171,
game 7172, map `otservbr`, database/user/password `canary`, SHA-1 password
storage, and password authentication.

---

### Task 5: Build and configure OpenTibiaBR login-server

**Files:**
- Create: `.tools/login-server/` (ignored checkout)
- Create: `.tools/login-server/.env`
- Produce: `.tools/login-server/login-server.exe`

**Interfaces:**
- Consumes: `config.lua`, MariaDB, and Go.
- Produces: HTTP login on `127.0.0.1:8088` advertising world `127.0.0.1:7172`.

- [ ] **Step 1: Verify Go is missing or record its existing version**

```powershell
$go = Get-Command go -ErrorAction SilentlyContinue
if ($go) { go version } else { Write-Output 'Go is not installed' }
```

- [ ] **Step 2: Install Go when absent and refresh its process path**

```powershell
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
  winget install --exact --id GoLang.Go --accept-package-agreements --accept-source-agreements --silent
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
go version
```

- [ ] **Step 3: Clone, test, and build login-server from source**

```powershell
git clone https://github.com/opentibiabr/login-server.git .tools/login-server
Push-Location '.tools\login-server'
go test ./...
if ($LASTEXITCODE -ne 0) { Pop-Location; exit $LASTEXITCODE }
go build -o login-server.exe ./src/
if ($LASTEXITCODE -ne 0) { Pop-Location; exit $LASTEXITCODE }
git rev-parse HEAD
Pop-Location
```

- [ ] **Step 4: Create the login-server environment**

Create `.tools/login-server/.env` with `apply_patch` using this exact content:

```dotenv
SERVER_PATH=C:/Users/Marlon/Documents/OT
MYSQL_DBNAME=canary
MYSQL_HOST=127.0.0.1
MYSQL_PORT=3306
MYSQL_USER=canary
MYSQL_PASS=canary
ENV_LOG_LEVEL=debug
ENV_LOG_FILE=../logs/login-server.log
LOGIN_IP=127.0.0.1
LOGIN_HTTP_PORT=8088
LOGIN_GRPC_PORT=9090
RATE_LIMITER_BURST=5
RATE_LIMITER_RATE=2
SERVER_IP=127.0.0.1
SERVER_NAME=OpenTibiaBR Canary Local
SERVER_PORT=7172
SERVER_LOCATION=BRA
```

- [ ] **Step 5: Verify build artifact and environment contract**

```powershell
Get-Item '.tools\login-server\login-server.exe'
rg -n '^(SERVER_PATH|MYSQL_|LOGIN_|SERVER_)' '.tools\login-server\.env'
```

Expected: the executable exists and every advertised/database endpoint is local.

---

### Task 6: Download and configure the Tibia 15.25 client

**Files:**
- Create: `.tools/downloads/tibia-client-15.25.0a00a0.zip`
- Create: `.tools/tibia-client-15.25/`
- Modify: `.tools/tibia-client-15.25/conf/config.ini`

**Interfaces:**
- Consumes: the upstream client release and the Task 5 HTTP endpoint contract.
- Produces: a Windows Tibia client configured exclusively for localhost login.

- [ ] **Step 1: Download and checksum the client release**

```powershell
$clientArchive = '.tools\downloads\tibia-client-15.25.0a00a0.zip'
Invoke-WebRequest 'https://github.com/dudantas/tibia-client/releases/download/15.25.0a00a0/tibia-client-15.25.0a00a0.zip' -OutFile $clientArchive
$actual = (Get-FileHash $clientArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne '264361a161a7f7261fa08c4c3558939d209ae0cf14c860d456a4b90d4c49c943') { throw "Client checksum mismatch: $actual" }
```

- [ ] **Step 2: Extract and verify the expected release layout**

```powershell
Expand-Archive $clientArchive '.tools\tibia-client-15.25' -Force
Get-Item '.tools\tibia-client-15.25\bin\client.exe' -ErrorAction Stop
Get-Item '.tools\tibia-client-15.25\conf\config.ini' -ErrorAction Stop
```

- [ ] **Step 3: Point both client services at login-server**

Use `apply_patch` on `.tools/tibia-client-15.25/conf/config.ini` with this exact patch:

```diff
*** Begin Patch
*** Update File: C:\Users\Marlon\Documents\OT\.tools\tibia-client-15.25\conf\config.ini
@@
-loginWebService=http://127.0.0.1/login.php
-clientWebService=http://127.0.0.1/login.php
+loginWebService=http://127.0.0.1:8088/login
+clientWebService=http://127.0.0.1:8088/login
*** End Patch
```

- [ ] **Step 4: Verify no production login URL remains active**

```powershell
rg -n '^(loginWebService|clientWebService)=' '.tools\tibia-client-15.25\conf\config.ini'
```

Expected: both entries equal `http://127.0.0.1:8088/login`.

---

### Task 7: Start services and verify server/API readiness

**Files:**
- Create: `.tools/start-local.ps1`
- Create: `.tools/stop-local.ps1`
- Create: `.tools/logs/`
- Produce: `.tools/canary.pid`
- Produce: `.tools/login-server.pid`

**Interfaces:**
- Consumes: Tasks 2-6 artifacts.
- Produces: running MariaDB, Canary, and login-server with bounded readiness checks.

- [ ] **Step 1: Create the stop helper**

Create `.tools/stop-local.ps1` with `apply_patch` using this exact content:

```powershell
$ErrorActionPreference = 'SilentlyContinue'
foreach ($pidFile in @('.tools\login-server.pid', '.tools\canary.pid')) {
    if (Test-Path $pidFile) {
        $processId = [int](Get-Content $pidFile -Raw)
        Stop-Process -Id $processId -Force
        Remove-Item -LiteralPath $pidFile -Force
    }
}
```

- [ ] **Step 2: Create the start helper with condition-based readiness**

Create `.tools/start-local.ps1` with `apply_patch` using this exact content:

```powershell
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\Marlon\Documents\OT'
Set-Location $root
New-Item -ItemType Directory -Force '.tools\logs' | Out-Null
if ((Get-Service CanaryMariaDB).Status -ne 'Running') {
    throw 'CanaryMariaDB is not running'
}
& '.tools\stop-local.ps1'
$canary = Start-Process -FilePath '.\canary.exe' -WorkingDirectory $root -RedirectStandardOutput '.tools\logs\canary.stdout.log' -RedirectStandardError '.tools\logs\canary.stderr.log' -PassThru -WindowStyle Hidden
$canary.Id | Set-Content '.tools\canary.pid'
$deadline = (Get-Date).AddMinutes(5)
do {
    if ($canary.HasExited) { throw "Canary exited with $($canary.ExitCode)" }
    if (Get-NetTCPConnection -LocalPort 7172 -State Listen -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
if (-not (Get-NetTCPConnection -LocalPort 7172 -State Listen -ErrorAction SilentlyContinue)) { throw 'Canary game port did not become ready' }
$loginDir = Join-Path $root '.tools\login-server'
$login = Start-Process -FilePath (Join-Path $loginDir 'login-server.exe') -WorkingDirectory $loginDir -RedirectStandardOutput (Join-Path $root '.tools\logs\login-server.stdout.log') -RedirectStandardError (Join-Path $root '.tools\logs\login-server.stderr.log') -PassThru -WindowStyle Hidden
$login.Id | Set-Content '.tools\login-server.pid'
$deadline = (Get-Date).AddSeconds(60)
do {
    if ($login.HasExited) { throw "login-server exited with $($login.ExitCode)" }
    if (Get-NetTCPConnection -LocalPort 8088 -State Listen -ErrorAction SilentlyContinue) { break }
    Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $deadline)
if (-not (Get-NetTCPConnection -LocalPort 8088 -State Listen -ErrorAction SilentlyContinue)) { throw 'login-server HTTP port did not become ready' }
```

- [ ] **Step 3: Start the local stack**

```powershell
& '.tools\start-local.ps1'
```

- [ ] **Step 4: Verify processes and listeners**

```powershell
$canaryPid = [int](Get-Content '.tools\canary.pid' -Raw)
$loginPid = [int](Get-Content '.tools\login-server.pid' -Raw)
Get-Process -Id $canaryPid,$loginPid | Select-Object Id,ProcessName,StartTime
Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 3306,7171,7172,8088,9090 | Sort-Object LocalPort | Select-Object LocalAddress,LocalPort,OwningProcess
```

- [ ] **Step 5: Exercise the real GOD HTTP login**

```powershell
$body = @{
  type='login'; email='@god'; password='god';
  clientversion='15.25.0a00a0'; clienttype=5;
  devicecookie='codex-local-verification'; stayloggedin=$false
} | ConvertTo-Json
$response = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8088/login' -ContentType 'application/json' -Body $body
if ($response.playdata.characters.name -notcontains 'GOD') { throw 'GOD character missing from login response' }
$world = $response.playdata.worlds | Select-Object -First 1
if ($world.externaladdressunprotected -ne '127.0.0.1' -or $world.externalportunprotected -ne 7172) { throw 'Login response advertises a non-local world' }
$response.playdata.characters | Select-Object name,level,vocation,worldid
$world | Select-Object name,externaladdressunprotected,externalportunprotected
```

Expected: the response contains `GOD` and advertises `127.0.0.1:7172`.

---

### Task 8: Launch the client, enter the world, and run the completion audit

**Files:**
- Create: `.tools/login-god.ps1`
- Produce: `.tools/logs/client-before-login.png`
- Produce: `.tools/logs/client-after-login.png`

**Interfaces:**
- Consumes: the running Task 7 stack and configured Task 6 client.
- Produces: a live client session authenticated as `GOD` plus database/runtime evidence.

- [ ] **Step 1: Create the client launch and keyboard automation helper**

Create `.tools/login-god.ps1` with `apply_patch` using this exact content:

```powershell
$ErrorActionPreference = 'Stop'
$clientDir = 'C:\Users\Marlon\Documents\OT\.tools\tibia-client-15.25'
$client = Start-Process -FilePath (Join-Path $clientDir 'bin\client.exe') -WorkingDirectory $clientDir -PassThru
$shell = New-Object -ComObject WScript.Shell
$deadline = (Get-Date).AddSeconds(45)
do {
    if ($client.HasExited) { throw "Tibia client exited with $($client.ExitCode)" }
    $activated = $shell.AppActivate($client.Id)
    if ($activated) { break }
    Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
if (-not $activated) { throw 'Could not activate the Tibia client window' }
Start-Sleep -Seconds 5
$shell.SendKeys('@god')
$shell.SendKeys('{TAB}')
$shell.SendKeys('god')
$shell.SendKeys('{ENTER}')
Start-Sleep -Seconds 5
$shell.SendKeys('{ENTER}')
$client.Id | Set-Content 'C:\Users\Marlon\Documents\OT\.tools\tibia-client.pid'
```

- [ ] **Step 2: Launch the client and attempt the GOD login**

```powershell
& '.tools\login-god.ps1'
```

- [ ] **Step 3: Poll authoritative online state**

```powershell
$db = (Resolve-Path '.tools\mariadb\bin\mariadb.exe').Path
$deadline = (Get-Date).AddSeconds(60)
do {
  $online = & $db --protocol=tcp -h127.0.0.1 -P3306 -ucanary -pcanary canary --batch --skip-column-names -e "SELECT p.name FROM players_online o JOIN players p ON p.id=o.player_id WHERE p.name='GOD';"
  if ($online -eq 'GOD') { break }
  Start-Sleep -Milliseconds 500
} while ((Get-Date) -lt $deadline)
if ($online -ne 'GOD') { throw 'GOD did not enter the game within 60 seconds' }
```

If the default focus order did not reach the login controls, capture the visible
client with the screenshot command in Step 4, inspect it with `view_image`, use
the Win32 cursor API to click the rendered email/password/login controls, and
repeat this same database assertion. The database assertion remains the gate.

- [ ] **Step 4: Capture visual evidence of the live client**

```powershell
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object System.Drawing.Bitmap $bounds.Width,$bounds.Height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location,[System.Drawing.Point]::Empty,$bounds.Size)
$bitmap.Save('C:\Users\Marlon\Documents\OT\.tools\logs\client-after-login.png',[System.Drawing.Imaging.ImageFormat]::Png)
$graphics.Dispose()
$bitmap.Dispose()
```

Inspect `.tools/logs/client-after-login.png` with `view_image` and confirm the
rendered game client is in the local world as `GOD`.

- [ ] **Step 5: Run fresh completion verification**

```powershell
git status --short --branch
git rev-parse HEAD
Get-FileHash '.\canary.exe' -Algorithm SHA256
& '.tools\vcpkg\vcpkg.exe' version
go version
& '.tools\mariadb\bin\mariadb.exe' --version
$canaryPid = [int](Get-Content '.tools\canary.pid' -Raw)
$loginPid = [int](Get-Content '.tools\login-server.pid' -Raw)
$clientPid = [int](Get-Content '.tools\tibia-client.pid' -Raw)
Get-Process -Id $canaryPid,$loginPid,$clientPid | Select-Object Id,ProcessName,StartTime
Get-NetTCPConnection -State Listen | Where-Object LocalPort -in 3306,7171,7172,8088,9090 | Sort-Object LocalPort
& $db --protocol=tcp -h127.0.0.1 -P3306 -ucanary -pcanary canary --batch --skip-column-names -e "SELECT value FROM server_config WHERE config='db_version'; SELECT a.email,a.type,p.name,p.group_id FROM accounts a JOIN players p ON p.account_id=a.id WHERE p.name='GOD'; SELECT p.name FROM players_online o JOIN players p ON p.id=o.player_id WHERE p.name='GOD';"
```

Expected: branch remains the setup branch, the compiled binary/hash exists,
all three processes are live, local ports are listening, schema version is 59,
the account/character privilege values are 6, and `GOD` is present in
`players_online`.

- [ ] **Step 6: Commit only the plan/spec documentation**

Generated runtime artifacts stay ignored. Verify there are no unintended tracked
changes, then commit this plan if it is still uncommitted:

```powershell
git status --short
git add docs/superpowers/plans/2026-10-03-canary-localhost.md
git diff --cached --check
git commit -m "docs: plan Canary localhost environment"
```
