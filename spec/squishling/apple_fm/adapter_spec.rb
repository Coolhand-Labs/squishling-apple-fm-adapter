# frozen_string_literal: true

require "bigdecimal"
require "fileutils"
require "timeout"
require "tmpdir"

RSpec.describe Squishling::AppleFM::Adapter do
  let(:dir) { Dir.mktmpdir("apple_fm_spec") }
  let(:record) { File.join(dir, "request.json") }
  let(:adapter) { described_class.new(helper: stub_helper({ content: '{"label":"ok"}' })) }

  after { FileUtils.remove_entry(dir) }

  # An executable that records what it is sent and prints a canned answer, standing in for the compiled Swift helper.
  def stub_helper(answer = nil, raw: nil, status: 0, sleep_for: 0, name: "helper")
    script_helper(<<~RUBY, name:)
      File.write(#{record.inspect}, $stdin.read)
      sleep #{sleep_for}
      print #{(raw || JSON.generate(answer)).inspect}
      exit #{status}
    RUBY
  end

  # An executable Ruby script with the given body.
  def script_helper(body, name: "helper")
    path = File.join(dir, name)
    File.write(path, "#!#{RbConfig.ruby}\n#{body}")
    FileUtils.chmod(0o755, path)
    path
  end

  # Both the request and what the helper writes are far bigger than a pipe buffer (about 64 KB).
  def oversized_request
    adapter_request(messages: [{ role: :user, content: "a" * 300_000 }])
  end

  # The call ends in the expected LLMError well inside the 10s Timeout guard, so a regression fails instead of hanging.
  def expect_call_to_fail(helper, message, timeout: 0.5, request: oversized_request)
    adapter = described_class.new(helper:, timeout:)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    Timeout.timeout(10) do
      expect { adapter.complete(request) }.to raise_error(Squishling::LLMError, message)
    end
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
  end

  def sent
    JSON.parse(File.read(record))
  end

  it "is registered as :apple_fm, built from a Hash of options" do
    Squishling.configure { |config| config.adapter = { type: :apple_fm, timeout: 30 } }

    expect(Squishling.config.adapter).to be_a(described_class)
    expect(Squishling.adapters).to include(:apple_fm)
  end

  describe ".register" do
    after { Squishling::AppleFM.register }

    it "registers the adapter again after Squishling.reset_adapters! forgot it, and is harmless when it is there" do
      Squishling.reset_adapters!
      expect(Squishling.adapters).not_to include(:apple_fm)

      2.times { Squishling::AppleFM.register }

      expect(Squishling.adapters).to include(:apple_fm)
    end
  end

  it "runs a squished class end to end, returning the same typed result as any adapter" do
    Squishling.configure do |config|
      config.adapter = described_class.new(helper: stub_helper({ content: '{"sentiment":"positive","note":null}' }))
      config.default_escalation = [{ model: "apple", attempts: 1 }]
    end
    klass = Class.new do
      include Squishling

      purpose "Classify the review."
      output_schema do
        string :sentiment, enum: %w[positive negative]
        optional(:note) { string }
      end

      def call(review:) = raise(NotImplementedError)
    end

    result = klass.new.call(review: "Loved it")

    expect(result).to have_attributes(sentiment: "positive", note: nil)
    expect(result.squished?).to be(true)
    expect(sent["schema"]["x-order"]).to eq(%w[sentiment note])
    expect(sent["schema"]["properties"]["note"]["anyOf"]).to eq([{ "type" => "string" }, { "type" => "null" }])
  end

  it "doesn't support judgments" do
    expect(adapter.judgments?).to be(false)
  end

  it "ships the Swift source the helper is compiled from" do
    expect(File).to exist(Squishling::AppleFM::Helper::SOURCE)
  end

  describe "#complete" do
    it "returns the helper's content, the on-device model's name, and its token counts" do
      adapter = described_class.new(helper: stub_helper(
        { content: '{"label":"ok"}', usage: { input_tokens: 12, output_tokens: 4 } }
      ))

      response = adapter.complete(adapter_request)

      expect(response).to have_attributes(content: '{"label":"ok"}', model: "apple-foundation-model",
        tokens: { input_tokens: 12, output_tokens: 4 })
    end

    it "sends the instructions, the conversation, and the schema in Apple's dialect" do
      request = adapter_request(messages: [{ role: :user, content: "first" }, { role: :assistant, content: "{}" },
                                           { role: :user, content: "again" }])
      adapter.complete(request)

      expect(sent).to include(
        "instructions" => "Classify.",
        "messages" => [{ "role" => "user", "content" => "first" }, { "role" => "assistant", "content" => "{}" },
                       { "role" => "user", "content" => "again" }]
      )
      expect(sent["schema"]).to include("title" => "Response", "x-order" => ["label"], "additionalProperties" => false,
        "required" => ["label"])
    end

    it "sends temperature and max_output_tokens, and nothing for params left unset" do
      adapter.complete(adapter_request(params: { temperature: 0.2, max_output_tokens: 300 }))
      expect(sent).to include("temperature" => 0.2, "max_tokens" => 300)

      adapter.complete(adapter_request)
      expect(sent.keys).not_to include("temperature", "max_tokens")
    end

    it "sends a BigDecimal or Rational temperature as a JSON number, which the helper would ignore as a string" do
      adapter.complete(adapter_request(params: { temperature: BigDecimal("0.5") }))
      expect(sent).to include("temperature" => 0.5)

      adapter.complete(adapter_request(params: { temperature: Rational(1, 2) }))
      expect(sent).to include("temperature" => 0.5)
    end

    it "accepts a temperature of 0 or a whole number, and ignores params set to nil" do
      adapter.complete(adapter_request(params: { temperature: 0 }))
      expect(sent).to include("temperature" => 0)

      adapter.complete(adapter_request(params: { temperature: 1 }))
      expect(sent).to include("temperature" => 1)

      adapter.complete(adapter_request(params: { temperature: nil, max_output_tokens: nil }))
      expect(sent.keys).not_to include("temperature", "max_tokens")
    end

    {
      temperature: [[-0.1, Float::NAN, Float::INFINITY, 10**400, BigDecimal("1e400"), "0.5", true, Complex(1, 1)],
                    "a finite number of 0 or more"],
      max_output_tokens: [[0, -5, 1.5, "100", true, false, 2**63], "a positive Integer that fits in 64 bits"]
    }.each do |name, (values, expected)|
      values.each do |value|
        it "raises ConfigurationError, naming only the param, for #{name}: #{value.inspect[0, 24]}" do
          expect { adapter.complete(adapter_request(params: { name => value })) }
            .to raise_error(Squishling::ConfigurationError, "Klass#call: the #{name} param must be #{expected}")
          expect(File.exist?(record)).to be(false)
        end
      end
    end

    it "reports a reply the output cap cut off as :max_tokens, so Squishling can tell a cutoff from a wrong answer" do
      adapter = described_class.new(helper: stub_helper({ content: "", finish_reason: "max_tokens" }))

      response = adapter.complete(adapter_request(params: { max_output_tokens: 5 }))

      expect(response).to have_attributes(content: "", finish_reason: :max_tokens, truncated?: true)
    end

    it "reports no finish reason for an ordinary answer, and drops one it doesn't know" do
      expect(adapter.complete(adapter_request).finish_reason).to be_nil

      odd = described_class.new(helper: stub_helper({ content: "{}", finish_reason: "Apple says: secret" }))
      expect(odd.complete(adapter_request).finish_reason).to be_nil
    end

    it "ignores the model name: the system has one model" do
      expect(adapter.complete(adapter_request(model: "anything")).model).to eq("apple-foundation-model")
      expect(adapter.complete(adapter_request(model: nil)).model).to eq("apple-foundation-model")
    end

    it "reports no tokens when the helper counted none, and ignores counts that aren't integers" do
      expect(adapter.complete(adapter_request).tokens).to eq({})

      odd = described_class.new(helper: stub_helper({ content: "{}",
usage: { input_tokens: "7", output_tokens: 3, x: 1 } }))
      expect(odd.complete(adapter_request).tokens).to eq({ output_tokens: 3 })
    end

    it "accepts thinking: false, but not thinking or any other param the system has no use for" do
      expect { adapter.complete(adapter_request(params: { thinking: false })) }.not_to raise_error

      [{ thinking: true }, { thinking: { effort: :low } }, { top_p: 0.5 }].each do |params|
        expect { adapter.complete(adapter_request(params:)) }
          .to raise_error(Squishling::ConfigurationError,
            /Klass#call: .*takes only the temperature and max_output_tokens/)
      end
    end

    it "names an unsupported param in the error, never its value" do
      expect { adapter.complete(adapter_request(params: { top_p: 0.987, thinking: { budget: 4321 } })) }
        .to raise_error(Squishling::ConfigurationError) { |error|
          expect(error.message).to include("top_p, thinking")
          expect(error.message).not_to match(/0\.987|4321/)
        }
    end

    describe "with ignore_unsupported_params" do
      let(:adapter) do
        described_class.new(helper: stub_helper({ content: '{"label":"ok"}' }), ignore_unsupported_params: true)
      end

      it "drops every param but temperature and max_output_tokens, whatever the value of thinking" do
        [{ budget: 4096 }, { budget: -1 }, { effort: :low }, true, false].each do |thinking|
          params = { temperature: 0.2, max_output_tokens: 300, thinking:, top_p: 0.5,
                     generationConfig: { thinkingConfig: { thinkingBudget: 0 } } }

          expect { adapter.complete(adapter_request(params:)) }.not_to raise_error
          expect(sent.keys).to contain_exactly("instructions", "messages", "schema", "temperature", "max_tokens")
          expect(sent).to include("temperature" => 0.2, "max_tokens" => 300)
        end
      end

      it "still validates temperature and max_output_tokens, which it does send" do
        [{ temperature: -1 }, { max_output_tokens: 0 }].each do |params|
          expect { adapter.complete(adapter_request(params: { top_p: 0.5, **params })) }
            .to raise_error(Squishling::ConfigurationError, /param must be/)
        end
      end
    end

    describe "when the helper reports an error" do
      def failing(code, **extra)
        described_class.new(helper: stub_helper({ error: code, message: "SECRET model text", **extra }))
      end

      %w[device_not_eligible apple_intelligence_not_enabled unsupported_schema bad_request].each do |code|
        it "raises ConfigurationError for #{code} (a setup mistake: never retried)" do
          expect { failing(code).complete(adapter_request) }
            .to raise_error(Squishling::ConfigurationError, /\AKlass#call: /)
        end
      end

      %w[context_window guardrail unsupported_language rate_limited model_not_ready generation other].each do |code|
        it "raises LLMError for #{code} (worth another attempt)" do
          expect { failing(code).complete(adapter_request) }.to raise_error(Squishling::LLMError, /\AKlass#call: /)
        end
      end

      it "names the context window when the request didn't fit" do
        expect { failing("context_window").complete(adapter_request) }
          .to raise_error(Squishling::LLMError, /4096-token context window/)
      end

      it "never repeats the helper's or the system's own message" do
        expect { failing("guardrail").complete(adapter_request) }
          .to raise_error(Squishling::LLMError) { |error| expect(error.message).not_to include("SECRET") }
        expect { failing("mystery").complete(adapter_request) }
          .to raise_error(Squishling::LLMError) { |error| expect(error.message).not_to include("mystery", "SECRET") }
      end
    end

    describe "when the helper misbehaves" do
      it "raises LLMError when it exits without an answer" do
        adapter = described_class.new(helper: stub_helper(raw: "", status: 1))

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /no answer \(exit 1\)/)
      end

      it "raises LLMError for an answer that isn't JSON, or isn't a JSON object" do
        ["not json", "[1,2]"].each do |raw|
          adapter = described_class.new(helper: stub_helper(raw:))

          expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /helper/)
        end
      end

      it "ignores a finish reason on an error answer: the error code decides" do
        adapter = described_class.new(helper: stub_helper({ error: "guardrail", finish_reason: "max_tokens" }))

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /Apple's safety guardrails/)
      end

      it "raises LLMError when an answer has neither content nor an error" do
        adapter = described_class.new(helper: stub_helper({ nothing: true }))

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /on-device model failed/)
      end

      it "stops waiting after the timeout and raises LLMError" do
        adapter = described_class.new(helper: stub_helper({ content: "{}" }, sleep_for: 5), timeout: 0.3)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /took longer than 0.3s/)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      end

      it "times out, not hangs, when the helper never reads a request bigger than the pipe buffer" do
        expect_call_to_fail(script_helper("sleep 30"), /took longer than 0.5s/)
      end

      it "times out, not hangs, when the helper fills its stdout before it reads all of stdin" do
        helper = script_helper(<<~RUBY)
          $stdout.write("x" * 300_000)
          $stdout.flush
          $stdin.read
          sleep 30
        RUBY

        expect_call_to_fail(helper, /took longer than 0.5s/)
      end

      it "raises LLMError, not hangs, when the helper exits without reading a request bigger than the pipe buffer" do
        expect_call_to_fail(script_helper("exit 3"), /no answer \(exit 3\)/, timeout: 5)
      end

      it "times out, not hangs, when the helper answers and closes stdout but doesn't exit" do
        helper = script_helper(<<~RUBY)
          $stdin.read
          print #{JSON.generate({ content: '{}' }).inspect}
          $stdout.flush
          $stdout.reopen(File::NULL, "w") # IO#close leaves fds 0-2 open, so the pipe would stay open
          sleep 30
        RUBY

        expect_call_to_fail(helper, /took longer than 0.5s/, request: adapter_request)
      end

      it "still raises LLMError when the helper exits on its own just before it is killed" do
        adapter = described_class.new(helper: stub_helper({ content: "{}" }, sleep_for: 1), timeout: 0.2)
        allow(Process).to receive(:kill).and_wrap_original do |original, *args|
          original.call(*args)
          raise Errno::ESRCH
        end

        expect { adapter.complete(adapter_request) }.to raise_error(Squishling::LLMError, /took longer than/)
      end

      it "raises ConfigurationError, naming the helper, when it can't be run" do
        missing = File.join(dir, "missing")
        adapter = described_class.new(helper: missing)

        expect { adapter.complete(adapter_request) }
          .to raise_error(Squishling::ConfigurationError, /helper #{Regexp.escape(missing.inspect)} can't be run/)
      end
    end

    it "runs a helper whose path has spaces and shell metacharacters, without involving a shell" do
      directory = File.join(dir, "Mary Ann; it's $(false) & co")
      FileUtils.mkdir_p(directory)
      path = stub_helper({ content: '{"label":"ok"}' }, name: File.join("Mary Ann; it's $(false) & co", "helper"))
      adapter = described_class.new(helper: path)

      expect(adapter.complete(adapter_request).content).to eq('{"label":"ok"}')
    end

    it "can be called from several threads at once" do
      results = Array.new(4) { Thread.new { adapter.complete(adapter_request).content } }.map(&:value)

      expect(results).to all(eq('{"label":"ok"}'))
    end
  end

  describe "options" do
    it "rejects a timeout that isn't a positive number" do
      [0, -1, "30", nil].each do |timeout|
        expect { described_class.new(timeout:) }
          .to raise_error(Squishling::ConfigurationError, /timeout must be a positive number/)
      end
    end

    it "rejects an ignore_unsupported_params that isn't true or false" do
      [nil, "yes", 1].each do |value|
        expect { described_class.new(ignore_unsupported_params: value) }
          .to raise_error(Squishling::ConfigurationError, /ignore_unsupported_params must be true or false/)
      end
    end

    it "takes ignore_unsupported_params from a Hash" do
      Squishling.configure do |config|
        config.adapter = { type: :apple_fm, helper: stub_helper({ content: "{}" }), ignore_unsupported_params: true }
      end

      expect { Squishling.config.adapter.complete(adapter_request(params: { top_p: 0.5 })) }.not_to raise_error
      expect(sent.keys).not_to include("top_p")
    end

    it "stays strict when ignore_unsupported_params is false" do
      adapter = described_class.new(helper: stub_helper({ content: "{}" }), ignore_unsupported_params: false)

      expect { adapter.complete(adapter_request(params: { top_p: 0.5 })) }
        .to raise_error(Squishling::ConfigurationError, /top_p/)
    end

    it "rejects a helper or cache_dir that isn't a path" do
      expect { described_class.new(helper: 5) }.to raise_error(Squishling::ConfigurationError, /helper must be a path/)
      expect do
        described_class.new(cache_dir: [])
      end.to raise_error(Squishling::ConfigurationError, /cache_dir must be a path/)
    end

    it "rejects a blank helper or cache_dir, which would otherwise build under the filesystem root" do
      ["", "  "].each do |blank|
        expect { described_class.new(helper: blank) }
          .to raise_error(Squishling::ConfigurationError, /helper must be a path/)
        expect { described_class.new(cache_dir: blank) }
          .to raise_error(Squishling::ConfigurationError, /cache_dir must be a path/)
      end
    end

    it "accepts a Pathname for helper and cache_dir" do
      expect { described_class.new(helper: Pathname(dir), cache_dir: Pathname(dir)) }.not_to raise_error
    end

    it "rejects options it doesn't have when built from a Hash" do
      expect { Squishling.configure { |config| config.adapter = { type: :apple_fm, model: "x" } } }
        .to raise_error(Squishling::ConfigurationError, /doesn't take model/)
    end
  end

  describe "compiling the bundled helper" do
    let(:status) { instance_double(Process::Status, success?: true) }
    let(:cache) { File.join(dir, "cache") }

    before { stub_const("RUBY_PLATFORM", "arm64-darwin25") }

    # swiftc, faked: "compiles" by writing a helper that answers {"content": "{}"}.
    def fake_swiftc(compiler_status = status)
      allow(Open3).to receive(:capture2e) do |*command|
        output = command.last
        File.write(output, "#!#{RbConfig.ruby}\n$stdin.read\nprint '{\"content\":\"{}\"}'\n")
        FileUtils.chmod(0o755, output)
        ["", compiler_status]
      end
    end

    it "compiles the source with swiftc on first use and reuses the cached binary after that" do
      fake_swiftc
      first = described_class.new(cache_dir: cache)

      2.times { expect(first.complete(adapter_request).content).to eq("{}") }
      expect(described_class.new(cache_dir: cache).complete(adapter_request).content).to eq("{}")

      expect(Open3).to have_received(:capture2e)
        .with("swiftc", "-O", Squishling::AppleFM::Helper::SOURCE, "-o", a_string_starting_with(cache)).once
    end

    it "keys the cache by the source's digest, and leaves no temporary file behind" do
      fake_swiftc
      described_class.new(cache_dir: cache).complete(adapter_request)

      names = Dir.glob(File.join(cache, "*", "*")).map { |path| File.basename(path) }
      expect(names).to contain_exactly("helper", "helper.lock")
      expect(Dir.children(cache).first).to match(/\A\h{16}\z/)
    end

    it "creates the cache directories private to the user" do
      fake_swiftc
      described_class.new(cache_dir: cache).complete(adapter_request)

      private_dirs = [cache, *Dir.glob(File.join(cache, "*"))].select { |path| File.directory?(path) }
      expect(private_dirs.map { |path| File.stat(path).mode & 0o777 }).to all(eq(0o700))
    end

    it "raises ConfigurationError when swiftc fails, and caches nothing" do
      fake_swiftc(instance_double(Process::Status, success?: false))

      expect { described_class.new(cache_dir: cache).complete(adapter_request) }
        .to raise_error(Squishling::ConfigurationError, /compiling the apple_fm helper failed; run `swiftc/)
      expect(Dir.glob(File.join(cache, "*", "helper"))).to be_empty
    end

    it "compiles again if the cached binary was deleted while the process runs" do
      fake_swiftc
      adapter = described_class.new(cache_dir: cache)
      adapter.complete(adapter_request)
      FileUtils.rm_rf(cache)

      expect(adapter.complete(adapter_request).content).to eq("{}")
      expect(Open3).to have_received(:capture2e).twice
    end

    it "raises ConfigurationError, not a bare Errno, when the cache directory can't be written" do
      File.write(File.join(dir, "file"), "")
      blocked = File.join(dir, "file", "cache")

      expect { described_class.new(cache_dir: blocked).complete(adapter_request) }
        .to raise_error(Squishling::ConfigurationError, /can't be built in .*cache_dir/)
    end

    it "raises ConfigurationError when swiftc isn't installed" do
      allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT)

      expect { described_class.new(cache_dir: cache).complete(adapter_request) }
        .to raise_error(Squishling::ConfigurationError, /swiftc wasn't found.*xcode-select --install/)
    end

    it "raises ConfigurationError off macOS, without trying to compile" do
      stub_const("RUBY_PLATFORM", "x86_64-linux")
      allow(Open3).to receive(:capture2e)

      expect { described_class.new(cache_dir: cache).complete(adapter_request) }
        .to raise_error(Squishling::ConfigurationError, /needs macOS 26 or later on Apple Silicon/)
      expect(Open3).not_to have_received(:capture2e)
    end

    it "caches under ~/Library/Caches/squishling/apple_fm unless told otherwise" do
      allow(Dir).to receive(:home).and_return(dir)
      stub_const("ENV", ENV.to_h.except("XDG_CACHE_HOME"))
      fake_swiftc

      described_class.new.complete(adapter_request)

      expect(Dir.glob(File.join(dir, "Library", "Caches", "squishling", "apple_fm", "*", "helper"))).not_to be_empty
    end

    it "caches under $XDG_CACHE_HOME when that is set" do
      stub_const("ENV", ENV.to_h.merge("XDG_CACHE_HOME" => File.join(dir, "xdg")))
      fake_swiftc

      described_class.new.complete(adapter_request)

      expect(Dir.glob(File.join(dir, "xdg", "squishling", "apple_fm", "*", "helper"))).not_to be_empty
    end

    it "treats an empty $XDG_CACHE_HOME as unset, as the XDG spec says" do
      allow(Dir).to receive(:home).and_return(dir)
      stub_const("ENV", ENV.to_h.merge("XDG_CACHE_HOME" => " "))
      fake_swiftc

      described_class.new.complete(adapter_request)

      expect(Dir.glob(File.join(dir, "Library", "Caches", "squishling", "apple_fm", "*", "helper"))).not_to be_empty
    end
  end
end
