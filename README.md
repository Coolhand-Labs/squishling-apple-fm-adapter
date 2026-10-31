# squishling-apple_fm

[Squishling](https://github.com/Coolhand-Labs/squishling) adapter for **Apple Intelligence**: run your Ruby LLM calls
on the on-device model built into macOS 26 and later (Apple Foundation Models). No API key, no network, no cost, so
you can try Squishling and develop against it locally, then run production on a hosted model.

```ruby
# Gemfile
gem "squishling"
gem "squishling-apple_fm", group: :development
```

```ruby
Squishling.configure do |config|
  config.adapter = :apple_fm if Rails.env.development?   # or any check that says "on my Mac"
end

class SentimentClassifier
  include Squishling

  purpose "Classify the sentiment of the review."
  output_schema do
    string :sentiment, enum: %w[positive negative neutral]
    optional(:quote) { string }
  end
end

SentimentClassifier.call(review: "Loved it, would buy again!")
# => #<data sentiment="positive", quote=nil>, the same typed result a hosted model returns
```

## Requirements

- macOS 26 or later on Apple Silicon, with **Apple Intelligence turned on** (System Settings).
- Xcode or its Command Line Tools (`xcode-select --install`). Apple's FoundationModels framework is Swift-only, so the
  gem bundles a small Swift program and compiles it with your `swiftc` the first time it is needed (a few seconds). The
  binary is cached under `~/Library/Caches/squishling/apple_fm`, so later calls start in under a second.
- Ruby 3.3+ and a Squishling release with pluggable adapters.

It adds no other gem, runs no server, and makes no network request.

## Options

```ruby
config.adapter = { type: :apple_fm, timeout: 60 }
```

| Option | Default | Description |
|---|---|---|
| `timeout` | `120` | Seconds to wait for an answer before the call fails with an `LLMError`. |
| `helper` | compiled from the bundled source | The path of a prebuilt helper to run instead. |
| `cache_dir` | `~/Library/Caches/squishling/apple_fm` (or under `$XDG_CACHE_HOME`) | Where compiled helpers are kept. |

The system has one model, so `model:` and `provider:` are ignored. `temperature` and `max_output_tokens` are sent;
other params raise `Squishling::ConfigurationError`.

## Know the limits

This is a small on-device model, for **developing** the shape of a call, not for judging its quality:

- The **context window is 4096 tokens** for the prompt, schema, and answer together; a call that doesn't fit is an `LLMError`.
- It **leans toward `null` for `optional` fields**, even when the input has the value. Make a field required, with `[]`
  or `""` for "none", when it matters.
- It picks between choices less reliably than a hosted model.

## Documentation

- **[How it works](docs/how-it-works.md)**: the Swift helper and its cache, how schemas are translated for Apple's guided
  generation, how failures map to Squishling's errors, limits, and troubleshooting.
- [Squishling's adapters](https://github.com/Coolhand-Labs/squishling/blob/main/docs/adapters.md): the adapter contract
  and the other adapters.
- [Changelog](CHANGELOG.md)

## Development

```bash
bundle install
bundle exec rake                              # RSpec (offline: the Swift helper is stubbed) + RuboCop
bin/exhale dry --include-tests                # duplication gate
bin/exhale complexity                         # complexity gate
bundle exec ruby examples/apple_fm_example.rb # live, on a Mac with Apple Intelligence
```

See [AGENTS.md](AGENTS.md) for the design invariants and the release process.

## License

Apache-2.0. See [LICENSE](LICENSE).
