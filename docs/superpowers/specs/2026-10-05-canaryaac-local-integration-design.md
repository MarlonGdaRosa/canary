# CanaryAAC Local Integration Design

## Objective

Install and adapt `opentibiabr/canaryaac` as a localhost-only account website
for the existing Windows Canary environment. The website must create a normal
account and its first playable character in one operation. The player chooses
Sorcerer, Druid, Paladin, Knight, or Monk; the resulting character starts at
level 8 in Thais and can authenticate through the existing OpenTibiaBR
login-server and enter the Canary world.

## Success Criteria

The integration is complete only when all of the following are demonstrated on
the current machine:

- A pinned PHP 8.3 Windows runtime and Composer installation live under
  `.tools/` and do not modify the machine-wide PHP configuration or `PATH`.
- CanaryAAC is pinned to upstream revision
  `d9333dcf33d3f55cee476e9ee8ebfe3f28113c19` under `.tools/canaryaac`.
- The application and its static assets respond from
  `http://127.0.0.1:8080` and are not reachable through a non-loopback bind.
- The original CanaryAAC SQL is not imported directly. An adapted, idempotent
  migration adds only the required website columns and tables while preserving
  the existing Canary account/player definitions, data, foreign keys, and
  unique indexes.
- The creation form accepts one of the five supported base vocations and creates
  a normal account plus a level 8 character in Thais as one database
  transaction.
- New passwords use the Canary-compatible compact Argon2id representation and
  authenticate through `http://127.0.0.1:8088/login`.
- Duplicate or invalid input produces a user-facing validation error without
  creating a partial account or character.
- Existing account `god`, character `GOD`, and the current sample players remain
  unchanged.
- The existing local start and stop flow controls CanaryAAC with a dedicated PID
  and log, and repeated startup does not create duplicate web processes.
- A pre-migration database dump is created and a documented restore command can
  read it.

## Constraints

- This is a localhost development installation, not a production website.
- The source repository was archived on May 26, 2025. Pin its source and review
  its locked dependencies instead of treating `main` as a maintained release.
- Use the current MariaDB service, database `canary`, game server, login-server,
  and client installation. Do not replace or reinitialize them.
- Do not run the upstream `canaryaac.sql` as a whole. It removes the unique
  account-name index, changes `accounts.creation` from a Unix integer to a SQL
  timestamp, changes player columns, and seeds an obsolete administrative
  account.
- Keep the current `accounts.creation` and player persistence formats expected
  by Canary.
- Preserve support for the existing legacy SHA-1 GOD account. Newly created
  website accounts use Argon2id; the current Canary authentication code already
  accepts both representations.
- Keep PHP, Composer, application checkout, generated configuration, database
  dumps, process identifiers, and logs under the already ignored `.tools/`
  directory.
- Do not enable payments, donations, SMTP, password recovery, remote
  administration, or public networking in this phase.
- Do not alter gameplay balance, maps, items, quests, or existing player data.

## Architecture

The local environment gains a fifth component alongside MariaDB, Canary,
login-server, and the Tibia client:

1. A portable PHP 8.3 Non-Thread-Safe x64 runtime provides the CLI and built-in
   development web server.
2. A local Composer executable installs the dependencies locked by CanaryAAC.
3. The pinned CanaryAAC checkout renders the registration form and reads/writes
   the existing `canary` database through PDO MySQL.
4. A dedicated MariaDB login named for the local AAC limits database access to
   localhost and the `canary` schema.
5. A small PHP router serves real static files directly and sends application
   routes to CanaryAAC's `index.php`, replacing the Apache `.htaccess` behavior
   that PHP's built-in server does not provide.

The player-facing data flow is:

`Browser :8080 -> CanaryAAC -> MariaDB -> login-server :8088 -> Canary :7172`

The website does not proxy game login traffic. Port 8080 owns website/account
creation; port 8088 continues to own the official client login endpoint.

## Local Layout

```text
.tools/
├── php/
├── composer/
├── canaryaac/
│   ├── .env
│   └── router.php
├── backups/
│   └── canaryaac-preinstall-<timestamp>.sql
├── logs/
│   └── canaryaac.log
└── canaryaac.pid
```

The concrete timestamp in a backup filename is generated at installation time;
the installer records the selected file in its output. Runtime files remain
machine-local and ignored by Git.

## Runtime and Dependency Provisioning

Download an official supported PHP 8.3 Windows NTS x64 release and verify the
archive checksum published by PHP for that release. PHP 8.3 is selected over
8.2 because 8.2 reaches end of security support in December 2026, while 8.3
remains security-supported through December 2027. It is selected over newer
branches to reduce compatibility risk with the archived application and its
2022–2023 dependency constraints.

Create a local `php.ini` enabling only the extensions needed by the application:
PDO MySQL, MySQLi where required by dependencies, mbstring, curl, DOM/XML,
OpenSSL, fileinfo, GD, sodium, and Argon2 support built into PHP. Set an explicit
timezone matching the local environment and direct errors to the AAC log. The
site may display development errors only while bound to loopback.

Install Composer locally and run installation from the pinned lockfile without
development packages or plugins/scripts that are not required by the
application. Run `composer validate` and `composer audit`. A known critical
runtime advisory blocks completion. Unused payment packages should be removed
from the local fork if they are the only source of a blocking advisory; payment
features remain out of scope.

## Database Migration

Before any schema change, use the bundled `mariadb-dump.exe` to create a complete
single-database dump under `.tools/backups`. Verify that the dump is nonempty,
contains the `accounts` and `players` table definitions, and imports successfully
into a temporary validation database. Drop only that explicitly named temporary
database after verification; never test restoration over the live database.

Create an adapted idempotent migration derived from the current database schema
and the AAC's actual queries. The migration must:

- add `accounts.page_access` only if the column is absent, defaulting to zero;
- add `players.main` and `players.world` only if absent, with defaults that do
  not change current characters;
- create only the CanaryAAC-owned tables needed by enabled local pages;
- seed one local world pointing to `127.0.0.1:7172`;
- seed five website sample rows for vocation IDs 1, 2, 3, 4, and 9 using the
  current server's level 8 sample values and Thais town/position;
- seed website settings that enable vocation selection and disable maintenance,
  payments, and public integrations;
- keep `accounts.accounts_unique`, `players.players_unique`, all existing
  foreign keys, and the integer `accounts.creation` representation;
- avoid changing account IDs, inserting an administrator, or modifying any
  existing account/player row.

The runtime AAC database user receives only the data privileges required by the
enabled local pages. Schema changes are executed separately with the existing
installation administrator and are not available to web requests.

## Account and Character Creation

The form collects account name, e-mail, password/confirmation, character name,
sex, and one of the five allowed vocations. One local world is preselected.

Server-side validation is authoritative:

- account names must contain 3–32 ASCII letters or digits;
- character names must contain 5–29 ASCII letters separated by single spaces,
  start and end with a letter, and fit the current Canary name field;
- account and character uniqueness is checked before insertion and still
  enforced by database indexes;
- e-mail must be syntactically valid and unused by the website policy;
- passwords must match, contain 12–128 characters, and must not be HTML-
  transformed before hashing;
- vocation must be exactly one of 1, 2, 3, 4, or 9;
- world and sample data are looked up server-side rather than trusted from form
  fields;
- account type is 1 and character group is 1; client input cannot set either.

Creation runs in one PDO transaction. It inserts the account with a Unix
creation timestamp and compact Argon2id hash, obtains its generated ID, then
inserts a player cloned from the selected current sample. The player starts at
level 8 in town 8 (Thais) with the matching vocation's health, mana, capacity,
appearance, and position. Any exception rolls back both inserts. The user sees a
generic failure message; the local log receives the detailed exception without
printing the plaintext password or stored hash.

## Password Compatibility

Use the same Argon2id parameters already shared by the server and AAC design:

- memory cost: `1 << 16` KiB;
- time cost: 2;
- parallelism: 2.

CanaryAAC stores the compact `$<salt>$<hash>` form expected by Canary's Argon2
adapter. The existing GOD SHA-1 hash remains untouched. End-to-end verification,
not the unused `passwordType` label alone, proves compatibility.

## Startup and Shutdown

Extend the current machine-local PowerShell helpers so startup order becomes:

1. MariaDB service;
2. Canary;
3. login-server;
4. CanaryAAC.

Start PHP with an explicit executable, document root, router path, loopback
address, and port. Redirect stdout/stderr to `.tools/logs/canaryaac.log`, store
the process ID in `.tools/canaryaac.pid`, and pass readiness only after an HTTP
request receives a valid application response.

Repeated startup checks the recorded process identity and the listener before
starting anything. Shutdown validates that the PID belongs to the expected PHP
executable and AAC command line before stopping it. It must not terminate an
unrelated PHP process. Existing Canary and login-server shutdown behavior remains
unchanged.

Update the user-facing batch output to show:

```text
Site/ACC:       http://127.0.0.1:8080
Login do jogo:  http://127.0.0.1:8088/login
Jogo:           127.0.0.1:7172
```

## Error Handling

- Fail before migration if the database dump cannot be created and inspected.
- Fail before dependency installation if an archive checksum does not match.
- Preserve Composer audit output and block on critical runtime advisories.
- Treat schema shape mismatches as migration failures; do not coerce existing
  Canary columns to the archived AAC schema.
- Roll back account creation on any character insert failure.
- Convert duplicate-key errors into validation responses and keep raw SQL/PDO
  details out of the browser response.
- Reject startup when port 8080 is owned by an unrelated process.
- Keep bounded readiness attempts and report the log path on failure.

## Verification Strategy

Verification uses fresh, end-to-end evidence:

1. Record the pinned CanaryAAC revision, PHP version, Composer version, MariaDB
   version, and enabled PHP modules.
2. Run Composer validation and audit, then syntax-check every changed PHP file.
3. Compare the pre/post schema for `accounts` and `players`; confirm existing
   types, indexes, foreign keys, and rows are preserved.
4. Run the migration a second time and confirm it performs no destructive or
   duplicate operation.
5. Confirm port 8080 listens only on `127.0.0.1`; request the home page,
   registration form, and representative static assets.
6. Submit the real website form once for each of the five vocations using unique
   temporary names. Confirm each account is type 1 and each character is group
   1, level 8, in Thais, with the selected vocation.
7. Authenticate every temporary account against the existing login-server and
   verify that its character appears in the returned world list. Use one account
   to enter the world through the game client and confirm the server sees the
   level 8 character.
8. Exercise invalid e-mail, mismatched password, invalid vocation, duplicate
   account, and duplicate character cases. Confirm row counts do not change.
9. Force a controlled character-insert failure after account insertion and
   confirm the transaction leaves neither row behind.
10. Remove only the uniquely named temporary test accounts after verification;
    rely on the existing foreign key cascade for their temporary characters,
    then confirm GOD and all pre-existing samples remain.
11. Start twice, verify one AAC process, stop through the normal helper, and
    confirm port 8080 is released while MariaDB data remains intact.

## Public-Deployment Boundary

This design does not authorize exposing CanaryAAC to a LAN or the internet.
Before publication, perform a separate design and security review covering at
least maintained dependencies, TLS/reverse proxying, secure sessions/cookies,
CSRF, brute-force and registration rate limits, CAPTCHA/abuse controls, e-mail
verification and recovery, secret management, content security policy, upload
handling, administrative authorization, payment isolation, privacy, backups,
monitoring, and incident response.

## Out of Scope

- Public DNS, firewall rules, TLS, reverse proxy, or hosting.
- Payment providers, donations, coin purchases, and web shop transactions.
- SMTP, e-mail confirmation, password recovery, and two-factor authentication.
- Website visual redesign, branding, news, guild administration, auctions, and
  other community pages beyond what must render for the creation flow.
- Changes to the login-server protocol, Canary gameplay, current GOD account,
  existing characters, or server balance.
