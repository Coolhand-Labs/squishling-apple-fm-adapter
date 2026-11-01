# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
