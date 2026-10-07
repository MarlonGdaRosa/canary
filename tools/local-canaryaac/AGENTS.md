# CanaryAAC web boundary

Never return an arbitrary existing checkout file to the built-in PHP server, or
expose the checkout as a production document root. Serve only the explicit static
asset surface with canonical containment; execute only `public/index.php`.
Keep the maintained router and installed router identical. Validate changes with
`tests/php/RouterSecurityTest.php` and `tests/php/WebSecurityTest.php`, including
HEAD denial of private files and HTTP tests of CSRF/session/limiter behavior.

Signup must validate raw scalar fields before hashing; never HTML-sanitize passwords
or overwrite hashes during authentication. Account and first character must commit
on one PDO connection, with the normalized-email advisory lock held through commit
and a duplicate recheck inside the transaction. Preserve configured 2FA, rejecting
ambiguous records and storage failures. Validate with the account PHP tests and raw
duplicate-field HTTP cases. Enable compact Argon signup only after the actual login
server supports the same fixed profile; build and audit it with the maintained helper.

Release identity must be reconstructed from the pinned revision and all ordered
patches. Never package runtime directories or treat missing audit evidence as
success. Exclude credentials/generated state/PHP assets from public; validate
drift/reparse/output boundaries with Production.Tests. Lifecycle termination
requires executable/router/listener identity, process generation and a retained
OS handle; a PID alone is never ownership. Test mismatches with Lifecycle.Tests
without stopping live services.
