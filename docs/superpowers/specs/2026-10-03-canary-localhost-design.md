# Canary Localhost Environment Design

## Objective

Prepare this Windows machine as a complete local Canary development and play
environment. The result must include a Canary executable compiled from this
checkout, a local MariaDB database initialized from the matching schema, the
OpenTibiaBR HTTP login service, and a compatible Tibia 15.25 Windows client
configured for localhost. The existing GOD account must be able to authenticate,
list its characters, and enter the game world.

## Success Criteria

The work is complete only when all of the following are demonstrated from the
current machine:

- `cmake --preset windows-release` configures the checked-out source with the
  project-managed vcpkg installation.
- `cmake --build --preset windows-release --target canary` exits successfully
  and produces the Canary Windows executable.
- MariaDB contains the schema revision shipped by this checkout and its built-in
  GOD account and character.
- Canary reaches its ready state without a database, map, or asset error and
  listens on the configured localhost game/status ports.
- `opentibiabr/login-server`, built from source for Windows, responds on
  `http://127.0.0.1:8088/login` and returns the local world for valid GOD
  credentials.
- The Windows Tibia 15.25 client starts from the local tools directory, uses the
  local login URL, authenticates with `@god` / `god`, shows the `GOD` character,
  and successfully enters the local game world.
- A fresh verification records process state, listening ports, HTTP login
  behavior, server logs, and the client/world-login result.

## Constraints

- The selected Canary revision is the checked-out `main` revision at setup time.
- Follow `AGENTS.md` and `docs/building/local-validation.md`; use the maintained
  `windows-release` CMake/Ninja preset rather than creating an alternate build
  tree.
- The preset requires MSVC toolset `v145`. Install Visual Studio Community 2026
  with the native C++ workload, ATL, CMake tools, English language pack, and a
  Windows SDK instead of weakening the preset to fit Visual Studio 2022.
- The host is Windows 10 although current upstream documentation names Windows 11
  as supported. Attempt the maintained native workflow first. If the required
  v145 toolchain cannot run on this host, compile the same checkout in a local
  Linux container or WSL environment; do not substitute a downloaded Canary
  runtime binary for the required source build.
- Bind game and login services to localhost only. Do not create public firewall
  exposure or use production credentials.
- Keep downloaded dependencies and generated runtime files out of source
  control. Use the already ignored `.tools/`, `build/`, `config.lua`, and map
  paths.

## Architecture

The local environment has four cooperating processes/components:

1. The compiled Canary server owns game protocol handling and reads its datapack,
   map, RSA key, and `config.lua` from this checkout.
2. A local MariaDB Windows service stores the schema, accounts, characters, and
   runtime persistence. Canary and the login service use a dedicated `canary`
   database user scoped to the local database.
3. The Go `opentibiabr/login-server` process exposes the current-client HTTP
   login contract on port 8088 and advertises `127.0.0.1:7172` as the world
   endpoint.
4. The patched Tibia 15.25 client sends login requests to the HTTP login service,
   then connects directly to Canary for the selected character.

The data flow is:

`Tibia client -> HTTP :8088 -> login-server -> MariaDB -> world list -> Canary :7172 -> MariaDB`

## Local Layout

- Repository and Canary runtime root: `C:\Users\Marlon\Documents\OT`
- Canary build tree: `build\windows-release`
- Project-managed vcpkg clone: `.tools\vcpkg`
- Login-server checkout/build: `.tools\login-server`
- Tibia client: `.tools\tibia-client-15.25`
- Runtime configuration: `config.lua`
- Global map: `data-otservbr-global\world\otservbr.otbm`
- Operational logs: `.tools\logs`

All `.tools` content, build output, runtime configuration, executables, and the
large map file are already covered by the repository ignore policy.

## Provisioning and Build

Install or complete Visual Studio Community 2026 non-interactively using its
official installer, then initialize the build shell with its `VsDevCmd.bat`.
Clone Microsoft vcpkg under `.tools`, bootstrap it, and set `VCPKG_ROOT` inside
the same initialized shell before configuration and compilation. Use the Ninja
bundled with Visual Studio when necessary, as required by the local validation
guide.

Install MariaDB and Go from their Windows packages. Clone and build
`opentibiabr/login-server` from source with `go build`. Download the Windows
asset `tibia-client-15.25.0a00a0.zip` from the Game Client release recommended
by Canary, verify that the archive contains the expected executable/configuration,
and extract it under `.tools`.

Download the map from the Canary release URL used by the upstream quickstart
when it is absent. Copy `config.lua.dist` to the ignored `config.lua` and change
only local identity, port, map, and database values needed for this environment.

## Database and Credentials

Create the `canary` database using an explicit UTF-8 character set, create a
least-privileged local `canary` database user, and import this checkout's
`schema.sql`. The schema is the source of truth and already seeds:

- Account email/login: `@god`
- Account name: `god`
- Password: `god` (stored as the SHA-1 value expected by the configured server)
- Account type: `6`
- Character: `GOD`
- Character group: `6`

Do not add a second administrator account or change the built-in credentials.

## Client Configuration

Edit only the extracted client's local `conf\config.ini`. Set both
`loginWebService` and `clientWebService` to
`http://127.0.0.1:8088/login`. Preserve the release's assets and remaining
configuration. The client must be launched from its extracted directory so its
relative asset paths resolve correctly.

## Startup and Shutdown

Startup order is MariaDB, Canary, login-server, then the Tibia client. Each
dependent process starts only after the preceding service passes a bounded
readiness check. Shutdown stops the client/login-server/Canary processes started
for this environment while leaving the MariaDB Windows service installed and its
database intact.

Local helper scripts may be placed under `.tools` to capture the exact environment
variables and process IDs. They remain ignored machine-local artifacts because
they include local installation paths and credentials.

## Failure Handling

- Fail immediately when a required installer, archive, checksum/download, or
  compiler executable is unavailable.
- If CMake configuration fails, preserve its output, verify the active developer
  environment and `VCPKG_ROOT`, and repair only `build\windows-release` according
  to the cache recovery rules.
- If Canary fails before ready state, inspect the first database/map/asset error
  and correct its source rather than masking it with retries.
- If HTTP authentication fails, compare the login-server environment with the
  actual database row and server name/port advertised to the client.
- If character entry fails after a valid world list, correlate the Canary and
  login-server timestamps and confirm the advertised world endpoint is
  `127.0.0.1:7172`.

## Verification Strategy

Verification is end-to-end and uses fresh evidence:

1. Record the Canary source commit, Visual Studio/MSVC version, vcpkg revision,
   Go version, MariaDB version, and client release tag.
2. Run the maintained Release configure and build commands and record exit code
   zero plus the resulting executable path.
3. Query MariaDB for schema version, the GOD account type, and the GOD character
   group without printing stored password material.
4. Start Canary and login-server, confirm their readiness logs, and inspect the
   listeners on ports 7171/7172 and 8088.
5. Submit an actual login request for `@god` and confirm a successful response
   advertising the local world and GOD character.
6. Launch the Tibia executable, authenticate with `@god` / `god`, select `GOD`,
   and confirm in Canary logs/database state that the character entered the
   game. Keep the client open at the verified local session unless cleanup is
   needed to correct a failure.

## Out of Scope

This is a localhost development/play environment, not a production deployment.
Public networking, account registration website, MyAAC administration, domain
names, TLS, automatic backups, and changes to Canary gameplay/source behavior are
not required.
