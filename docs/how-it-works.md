# How it works

`squishling-apple_fm` runs Squishling's requests on Apple's on-device model (Apple Intelligence, through the
FoundationModels framework). Squishling builds the request, this adapter makes one completion, and Squishling does the
rest: validation, retries and escalation, harnesses, `squawk`, and fallbacks. See
[Squishling's adapter contract](https://github.com/Coolhand-Labs/squishling/blob/main/docs/adapters.md#writing-your-own).

## The Swift helper

FoundationModels is Swift-only: it has no C or Objective-C interface, so Ruby can't call it directly. The gem ships one
small Swift program, `lib/squishling/apple_fm/helper.swift`.

- **Built on first use** with the `swiftc` from Xcode or its Command Line Tools, into
  `~/Library/Caches/squishling/apple_fm/<digest of the source>/helper` (under `$XDG_CACHE_HOME` when that is set, or in
  `cache_dir:`). A new gem version with a changed source builds a new binary; old ones stay until you delete the
  directory. The build takes a few seconds, runs under a file lock so concurrent processes build once, and is renamed into
  place so nobody runs a half-written file. The cache directories are created readable only by you (mode 0700), because
  the binary's path is predictable; if you point `cache_dir:` at a directory that others can write to, they could put a
  binary there, so keep it private.
- **One process per request.** Ruby writes one JSON request to its stdin and reads one JSON line from its stdout, so there
  is no server, no shared state, and Squishling's concurrent samples each get their own process (about 0.8 seconds per
  call once built, mostly model time).
- **Private protocol.** The request is `{ instructions, messages, schema, temperature?, max_tokens? }`; the answer is
  `{ content, usage?, finish_reason? }` or `{ error: <code> }`. Apple's own error messages never leave the helper, only a code.
- **Token counts** (`usage`) come from FoundationModels on macOS 26.4 and later; on 26.0 to 26.3 there are none.
- `helper:` runs a prebuilt binary instead, for example one built in CI or by your own tooling. It is run as given, with
  no shell, so a path with spaces or other special characters works.

## Schemas

Squishling always sends a strict schema: every key required, `optional` fields as `anyOf: [T, null]`. Apple's guided
generation reads its own JSON Schema dialect, so the adapter translates it, and the model is constrained to the result:

| Squishling's schema | Sent to the model |
|---|---|
| objects | a `title`, `x-order` (the property order), and `additionalProperties: false` |
| `anyOf: [T, null]` (`optional`) | the same, with a `title` on the union (a real nullable) |
| `type: ["string", "null"]` (raw schemas) | split into `anyOf` |
| `$ref` / `$defs` | inlined (a schema that refers to itself raises `ConfigurationError`) |
| `enum`, `minimum`, `maximum`, `minItems`, `maxItems`, `description` | kept |
| `pattern`, `minLength`, `maxLength`, `format`, `const`, `default`, … | left out |

What is left out can't guide the model (some of it makes generation fail), but **Squishling validates every answer
against your full schema anyway**, so a value that breaks a `pattern` is still rejected and retried.

## Failures

| What happened | Raised | Notes |
|---|---|---|
| Not macOS, or an Apple Silicon Mac without macOS 26 | `ConfigurationError` | never retried |
| Apple Intelligence off, or the device ineligible | `ConfigurationError` | the message says to turn it on |
| `swiftc` missing, the compile fails, or the cache isn't writable | `ConfigurationError` | the message gives the command to run |
| A schema the model can't generate | `ConfigurationError` | |
| A param other than `temperature` / `max_output_tokens` | `ConfigurationError` | the message names the param, never its value; with `ignore_unsupported_params: true` it is dropped instead |
| A `temperature` that isn't a finite number of 0 or more, or a `max_output_tokens` that isn't a positive Integer that fits in 64 bits | `ConfigurationError` | the message names the param, never the value |
| A reply cut off by `max_output_tokens` | invalid output (retried) | the framework only reports a decoding failure, so any decoding failure with a limit set is treated as a cutoff; the answer is empty and `finish_reason` is `:max_tokens`, so Squishling says it was a cutoff. Raise the limit or ask for less |
| Prompt, schema, and answer over 4096 tokens | `LLMError` | depends on the input, so a retry or fallback may help |
| Apple's guardrails decline, a rate limit, the model still downloading, an unsupported language | `LLMError` | |
| The helper crashes, answers with garbage, or takes longer than `timeout` | `LLMError` | a timed-out helper is killed |

Messages carry only the kind of failure. The system's own message, the helper's stderr, and the model's output never
appear in an error or log.

### Ignoring unsupported params

A class written for a hosted model often pins params the on-device model has no equivalent for, such as
`thinking: { budget: 4096 }` or a provider's `generationConfig`. Set `ignore_unsupported_params: true` to run it here
unchanged: everything except `temperature` and `max_output_tokens` is dropped without a message, and `thinking` is
dropped whatever its value. `temperature` and `max_output_tokens` are still checked, since they are sent. It is off by default, so a param that does nothing still fails loudly. A value that isn't
`true` or `false` is a `ConfigurationError`.

## Limits of the model

It is a small on-device model, so it is for developing the shape of a call:

- **4096-token context window**, shared by the instructions, the conversation (a retry replays the rejected answer), the
  schema, and the answer.
- **An optional nested object comes back `null`.** Given a note that says "Heart rate 88", `optional :vitals { object {
  integer :heart_rate } }` was `null` in 10 of 10 runs, while the same field required returned 88 in 10 of 10, and a
  flat `optional(:heart_rate) { integer }` returned 88 in 10 of 10. The schema sent is the expected
  `anyOf: [object, null]`, so whether this is the model's preference for the `null` branch or something in how the
  union is written is not established; an earlier note that reordering the union or describing the field doesn't help
  has not been re-checked. Make the object required, with `[]` or `""` for "none" in its fields, if it matters.
- **It chooses less reliably** than a hosted model between enum values, so a classification can differ from production's.

## Troubleshooting

- `turn on Apple Intelligence in System Settings`: System Settings → Apple Intelligence & Siri. The first run may also
  download the model (`the on-device model isn't ready yet`); retry in a few minutes.
- `swiftc wasn't found`: `xcode-select --install`, or install Xcode.
- `compiling the apple_fm helper failed`: run the `swiftc` command in the message to see Swift's own output. The framework
  needs Xcode 26 or later.
- A stale or suspect binary: delete `~/Library/Caches/squishling/apple_fm`; it rebuilds on the next call.
