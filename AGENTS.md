# Development Guidelines

Rules for any agent (or human) working in this repo. `CLAUDE.md` imports this file.

## What this gem is

`squishling-apple_fm` is an adapter for [Squishling](https://github.com/Coolhand-Labs/squishling). It runs Squishling's
LLM calls on the on-device model built into macOS 26+ (Apple Intelligence, through the FoundationModels framework):
free, offline, and private, so developers can try and develop against Squishling with no API key and no bill. It is
meant for development, not production: the model is small (4096-token context window) and macOS-only.

FoundationModels is Swift-only (no C or Objective-C interface), so the gem ships one small Swift program
(`lib/squishling/apple_fm/helper.swift`). Ruby compiles it with the system's `swiftc` on first use, caches the binary
by the source's digest, and runs one process per request over stdin/stdout JSON.

## Verify before you push

```bash
bundle exec rake    # RSpec (offline, the Swift helper is stubbed) + RuboCop — both must pass
```

CI also runs [exhale](https://github.com/tools4imps/exhale-ruby) (duplication and complexity gate, whole-codebase
sweep). Run it locally with `bin/exhale dry --include-tests` and `bin/exhale complexity`; don't
introduce new duplicate code or methods over the complexity floor. CI also compiles the real Swift helper on a macOS
runner and checks its JSON protocol; run the same by hand with
`swiftc -O lib/squishling/apple_fm/helper.swift -o /tmp/apple_fm_helper`.

After the feature or fix is built and `rake` is green, run `/loop-review` until it comes back clean (see
[Review and release skills](#review-and-release-skills)).

The live test is `examples/apple_fm_example.rb` (and `examples/quickstart.rb`, the short version). It needs a Mac
with macOS 26+ on Apple Silicon and Apple Intelligence turned on, so it can't run in CI; it runs during
`/prep-release`. If you touch `helper.swift`, the schema translation, or the process handling, run it yourself first.
Never delete an assertion, mark a spec pending, or rescue-and-swallow to get green.

## Runtime dependencies

The gem's only runtime dependency is `squishling`. Keep it that way:

- **No other gem**, and no HTTP client: nothing here talks to a network. Ruby stdlib only (`Open3`, `Digest`,
  `FileUtils`, `JSON`).
- The Swift helper is built only with the `swiftc` the user already has (Xcode or its Command Line Tools). Never
  download, vendor, or ship a prebuilt binary: the cache holds only what the user's own compiler built from the
  shipped source.
- Development-only gems go in the `Gemfile`'s `:development, :test` group, never the gemspec.
- Squishling comes from RubyGems, never a git source: the gemspec requires `>= 0.5.0`, the first release with pluggable
  adapters (the `/prep-release` skill checks it). Raise it only when the adapter starts using something newer.
- No Ruby-version-conditional gems in the `Gemfile`: the committed `Gemfile.lock` is installed in frozen
  mode on every Ruby in the CI matrix (3.3–4.0), so it must resolve identically everywhere.
- `examples/`, `spec/`, `bin/`, and agent files are excluded from the packaged gem (see the gemspec). `helper.swift`
  must stay in it.

## Design invariants

Flag any change that breaks one of these; they are behavior contracts, not style. The adapter contract itself is
Squishling's (`Squishling::Adapter::Base`, see its AGENTS.md); these are what this gem adds to it.

- **Only the public Squishling API.** Use `Squishling.register_adapter`, `Squishling::Adapter::Base`/`Request`/`Response`,
  and the error classes (plus `Squishling.reset_config!` in `spec/spec_helper.rb` only, which Squishling's docs recommend for
  test suites). Don't reach into Squishling internals (`Schema`, `Invoker`, `LLMClient`, registries) from `lib/`
  or `spec/`: this gem is a plugin and has to survive Squishling's refactors.
- **Errors.** The adapter raises only `ConfigurationError` (setup mistakes: never retried or escalated) or `LLMError`
  (worth another attempt); any other exception propagates unwrapped. A setup mistake is a Mac that can't run Apple
  Intelligence or has it off, a missing or failing `swiftc`, an unwritable cache, an unusable helper path, a schema the
  model can't generate, or a param the adapter doesn't take. A context-window overflow, a guardrail refusal, a model
  that is still downloading, a rate limit, a crash, and a timeout are `LLMError`s. A `max_output_tokens` cutoff is not
  an error: it is a `Response` with empty content and `finish_reason: :max_tokens`, which Squishling treats as invalid
  output (and says was a cutoff). The helper infers it, since the framework only reports a decoding failure: any
  decoding failure with a limit set.
- **Nothing from the system or the model in an error or log.** The Swift helper answers with a fixed error *code*, never
  Apple's own message; the Ruby side maps codes to its own texts, and an unknown code gets a generic one. Model output
  leaves only as the `Response` content. Don't echo the helper's stderr (it is discarded) or compiler output.
- **One process per request.** Adapters run on worker threads for Squishling's samples, so there is no shared helper
  process and no unsynchronized state. The build is guarded by a per-adapter mutex and a cross-process `flock`, and the
  binary is renamed into place, so nobody runs a half-written file.
- **The helper speaks one protocol.** It reads one JSON request from stdin, writes exactly one JSON object line to
  stdout (`{"content", "usage", "finish_reason"}`, the last only `"max_tokens"` for a reply the output cap cut off, or
  `{"error": <code>}`), and exits 0 whenever it wrote a line. Anything else is treated as a crash (`LLMError`). The
  protocol is private to this gem, so Ruby and Swift change together. APIs newer than macOS 26.0 (token counts need
  26.4) sit behind `#available`.
- **Strict schemas in, Apple's dialect out.** `GenerationSchema` translates Squishling's strict schema into the dialect
  Apple's decoder reads (titles, `x-order`, explicit `additionalProperties`, `anyOf` with null for nullable, `$ref`
  inlined, `type: [..., "null"]` split). It keeps only the keywords the model can be guided by and never mutates its
  input. What it drops (`pattern`, `minLength`, `format`, `const`, ...) is still enforced by Squishling's own
  validation, which is the guarantee: the model's compliance is never trusted.
- **Params.** Only `temperature` and `max_output_tokens` are sent; `thinking` (anything but `false`) and every other
  param raise `ConfigurationError`. `model:` and `provider:` are ignored: the system has one model.
- **Platform honesty.** Off macOS the adapter raises `ConfigurationError` when it would have to build; it never pretends.
  Requiring the gem on a Squishling without `register_adapter` raises `LoadError` with the fix.

## Public API

`require "squishling/apple_fm"` registers the adapter as `:apple_fm`. The public surface is that adapter name and its
options (`timeout:`, `helper:`, `cache_dir:`), `Squishling::AppleFM::Adapter`, `Squishling::AppleFM.register`, and
`Squishling::AppleFM::VERSION`. `Helper` and `GenerationSchema` are internal. Don't break the public surface without a
clear migration path in the changelog.

## Changelog and versioning

Do not add `CHANGELOG.md` entries or bump `lib/squishling/apple_fm/version.rb` on feature/fix branches or in PRs. The
`/prep-release` skill is the sole owner of both — it writes changelog entries for the PRs actually shipping in
a release and bumps the version once, at release time.

Per-PR changelog edits create merge conflicts across concurrent branches for no benefit, since the entries get
rewritten from the final, user-approved set of merged PRs anyway. Leave `CHANGELOG.md` and `version.rb` alone
in your PR.

Releases publish to RubyGems via Trusted Publishing when a `vX.Y.Z` tag is pushed (`.github/workflows/publish.yml`).
Agents never create or push tags, run `rake release`, or `gem push`. The one exception: `/finish-release`, invoked
by the user, is the sanctioned path for merging the release PR and pushing the release tag (it still never runs
`rake release` or `gem push`).

## Commits and PRs

Author commits and PRs as the local machine's GitHub user (whatever `git config user.name`/`user.email` and
`gh api user` report), never as Claude or any other agent. Don't add `Co-Authored-By: Claude` trailers or
"Generated with Claude Code" footers to commit messages or PR descriptions. A human owns every change, and a
single, accurate author makes it easy to track who is responsible for what.

## README and docs philosophy

The README is a landing page — what it is, install, quick start, requirements, where to go next. Keep it scannable.
When in doubt, link rather than expand. Anything needing more than one code block, or deeper explanation (how the
helper is built and cached, schema translation, failure mapping, limits, troubleshooting), goes in
`docs/how-it-works.md` or a new `docs/<topic>.md`, linked from the README.

Use full names ("Apple Intelligence", "Apple Foundation Models", "Ruby LLM structured output") in headings and the
gemspec description, so searches for "Ruby Apple Intelligence", "Ruby on-device LLM", or "Squishling adapter" find it.

## Review and release skills

- `/loop-review` (`.claude/skills/loop-review/SKILL.md`) — iterative review-and-fix of the current diff.
  **Always run it after building a feature or fix, before committing or pushing the branch** — don't wait to be
  asked. Report its result (clean or the remaining findings) along with the work.
- `/prep-release` (`.claude/skills/prep-release/SKILL.md`) — the release event: PR triage, merges,
  changelog/version, security red-team, the live example on a Mac, release-prep PR.
- `/finish-release` (`.claude/skills/finish-release/SKILL.md`) — after you've reviewed the release-prep PR:
  squash-merges it, pushes the annotated `vX.Y.Z` tag (which triggers the Publish workflow), and publishes the
  GitHub release notes. Invoking it is the authorization to merge, tag, and publish.
