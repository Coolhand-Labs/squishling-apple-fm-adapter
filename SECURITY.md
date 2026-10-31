# Security Policy

## Supported Versions

Only the latest published version of `squishling-apple_fm` on RubyGems is supported with security fixes.
Please upgrade to the latest version before reporting an issue.

## Reporting a Vulnerability

Please do **not** open a public GitHub issue for security vulnerabilities.

Instead, report vulnerabilities privately using one of the following:

- [GitHub Security Advisories](https://github.com/Coolhand-Labs/squishling-apple-fm-adapter/security/advisories/new)
  for this repository (preferred)
- Email team@coolhandlabs.com

Please include a description of the vulnerability, steps to reproduce, and the impact you believe
it has. We aim to acknowledge reports within 3 business days and to provide a fix or mitigation
plan within 30 days, depending on severity.

## What this gem runs

The gem compiles `lib/squishling/apple_fm/helper.swift` with the `swiftc` on your machine and runs the resulting binary
(cached under `~/Library/Caches/squishling/apple_fm`, or `$XDG_CACHE_HOME`) once per request. It never downloads or ships
a prebuilt binary. Anyone who can write to that cache directory can already run code as you, so keep it user-private;
the `helper:` option runs whatever path you give it. Reports about the helper, the cache, or the request/response
handling are in scope.
