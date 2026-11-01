# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-11-01

### Fixed

- `timeout:` now covers writing the request to a custom `helper:` too. Before, a helper that filled its output before
  reading its input (or never read it) hung forever on a request bigger than the pipe buffer (about 64 KB); the call now
  fails with an `LLMError` once `timeout:` has passed, as it does for a helper that never answers. The bundled helper
  was not affected. (#10)
- A `temperature` that isn't a finite number of 0 or more, or a `max_output_tokens` that isn't a positive Integer
  (it must fit in 64 bits), now raises a `ConfigurationError` that names the param and never its value. Before, a
  `max_output_tokens` of 0 or less was reported as an output cutoff (and retried as invalid output), and a negative
  temperature was silently accepted. Valid values are unaffected; a `BigDecimal` or `Rational` temperature is now sent
  as a number instead of being dropped. (#9)

## [0.1.0] - 2026-11-01

First release.

### Added

- A Squishling adapter for Apple Intelligence, registered as `:apple_fm`: Squishling's LLM calls run on the on-device
  model built into macOS 26 and later (Apple Foundation Models), with no API key, no network, and no cost. Meant for
  developing against Squishling locally; the model is small (4096-token context window) and macOS-only. Options:
  `timeout:`, `helper:`, `cache_dir:`. Needs Squishling 0.5.0 or later. (#1, #4)
- A small Swift helper that the gem compiles with your own `swiftc` on first use, caches by the source's digest, and runs
  once per request over stdin/stdout JSON. Nothing is downloaded or shipped prebuilt. (#1)
- Strict structured output: Squishling's strict schema is translated into Apple's guided generation, and Squishling still
  validates every answer against your full schema. (#1)
- A reply cut off by `max_output_tokens` is reported to Squishling as a cutoff (`finish_reason: :max_tokens`), so
  `InvalidOutputError#truncated?` says so instead of a generic failure. (#4)
- Live smoke tests in `examples/` (`quickstart.rb` and `apple_fm_example.rb`) for a Mac with Apple Intelligence. (#4)

### Security

- The helper is started with no shell, so a cache or helper path containing spaces or shell characters (for example a
  home directory like `/Users/Mary Ann`) is run as given instead of being split or interpreted.
- The helper cache directories are created with mode 0700.
- A blank `helper:` or `cache_dir:` is rejected with a `ConfigurationError` instead of building under the filesystem root.
