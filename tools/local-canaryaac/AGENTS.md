# CanaryAAC web boundary

Never return an arbitrary existing checkout file to the built-in PHP server, or
expose the checkout as a production document root. Serve only the explicit static
asset surface with canonical containment; execute only `public/index.php`.
Keep the maintained router and installed router identical. Validate changes with
`tests/php/RouterSecurityTest.php` and `tests/php/WebSecurityTest.php`, including
HEAD denial of private files and HTTP tests of CSRF/session/limiter behavior.
