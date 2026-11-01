# frozen_string_literal: true

# Live tests: Squishling scenarios through the :apple_fm adapter, on the on-device model built into macOS. No API key,
# no network, no cost. Needs macOS 26 or later on Apple Silicon with Apple Intelligence on, and Xcode or its Command
# Line Tools (the first run compiles the Swift helper, a few seconds). The model has a 4096-token context window.
#
# The scenarios check what the adapter does (typed results, nullable fields, multi-turn retries, token usage, concurrent
# samples, error mapping), not how well a small model answers, so they assert on shapes and types rather than on exact
# answers. Run: bundle exec ruby examples/apple_fm_example.rb
# Exits 0 when every scenario passes, 1 otherwise (including on a Mac that can't run Apple Intelligence).
# examples/quickstart.rb is the five-line version, for checking that a fresh install works.

require "bundler/setup"
require "fileutils"
require "tmpdir"
require "squishling/apple_fm"

Squishling.configure do |config|
  config.adapter = :apple_fm
  config.default_escalation = [{ model: "apple-foundation-model", attempts: 2 }]
  config.default_params = { temperature: 0.2 }
end

Scenario = Struct.new(:name, :block)

def check(condition, message)
  raise message unless condition
end

# The squished classes the scenarios call.
module Fixtures
  class Reviewer
    include Squishling

    purpose "Classify the sentiment of the product review and rate it from 1 to 5."
    output_schema do
      string :sentiment, enum: %w[positive negative neutral]
      integer :score, minimum: 1, maximum: 5
      optional(:quote) { string }
    end
  end

  class InvoiceReader
    include Squishling

    purpose "Extract the invoice number, the line items, and the total."
    output_schema do
      string :invoice_number
      array :line_items do
        object do
          string :description
          integer :quantity
          number :unit_price
        end
      end
      number :total
    end
  end

  # A raw JSON Schema hash with the nullable written as a type array, which Apple's decoder doesn't read as is.
  class RawNullable
    include Squishling

    purpose "Classify the review."
    output_schema(
      type: "object",
      properties: { sentiment: { type: "string", enum: %w[positive negative] }, note: { type: %w[string null] } },
      required: %w[sentiment note], additionalProperties: false
    )
  end

  # squish_validate rejects the first answer, so the call asks again with the rejected output in the conversation.
  class CheckedColor
    include Squishling

    purpose "Reply with one lowercase word that names a color."
    output_schema { string :word }
    squish_validate do |result, **|
      @checks = (@checks || 0) + 1
      "pick a different color than #{result.word.inspect}" if @checks == 1
    end
    attr_reader :checks
  end

  class Fallback
    include Squishling

    purpose "Reply with one word."
    output_schema { string :word }
    squish_fallback { |_error, **| { word: "fallback" } }
  end
end

# An adapter-level request for the scenarios that call the adapter without Squishling: one string field, "word".
def word_request
  schema = { "type" => "object", "properties" => { "word" => { "type" => "string" } }, "required" => ["word"],
             "additionalProperties" => false }
  Squishling::Adapter::Request.new(
    label: "Example#call", model: nil, provider: nil, instructions: "Reply with one word.",
    messages: [{ role: :user, content: "hi" }], params: {},
    schema: { "name" => "Word", "strict" => true, "schema" => schema }
  )
end

REVIEW = "Absolutely love it. Best purchase I've made all year."
INVOICE = "Invoice #INV-2041\n3 x Widget @ $10.00\n2 x Gadget @ $25.00\nTOTAL DUE: $80.00"

SCENARIOS = [
  Scenario.new("an enum and a numeric range come back as a typed result", lambda {
    result = Fixtures::Reviewer.call(review: REVIEW)
    check(result.squished?, "expected an LLM result")
    check(%w[positive negative neutral].include?(result.sentiment), "sentiment was #{result.sentiment.inspect}")
    check(result.score.is_a?(Integer) && (1..5).cover?(result.score), "score was #{result.score.inspect}")
    "#{result.sentiment} #{result.score}"
  }),
  Scenario.new("an optional field is a String or nil, never missing", lambda {
    result = Fixtures::Reviewer.call(review: REVIEW)
    check(result.to_h.key?(:quote), "quote was missing")
    check(result.quote.nil? || result.quote.is_a?(String), "quote was #{result.quote.inspect}")
    "quote=#{result.quote.inspect}"
  }),
  Scenario.new("nested objects and arrays of objects are typed", lambda {
    result = Fixtures::InvoiceReader.call(text: INVOICE)
    check(result.line_items.is_a?(Array) && result.line_items.all?(Data),
      "line_items were #{result.line_items.inspect}")
    check(result.line_items.all? { |item| item.quantity.is_a?(Integer) && item.unit_price.is_a?(Numeric) },
      "line items had the wrong types: #{result.line_items.inspect}")
    check(result.total.is_a?(Numeric), "total was #{result.total.inspect}")
    "#{result.invoice_number}, #{result.line_items.size} items, total #{result.total}"
  }),
  Scenario.new("a raw schema with type: [string, null] is translated for the model", lambda {
    result = Fixtures::RawNullable.call(review: REVIEW)
    check(result.note.nil? || result.note.is_a?(String), "note was #{result.note.inspect}")
    "note=#{result.note.inspect}"
  }),
  Scenario.new("squish_validate rejection retries with the conversation so far", lambda {
    instance = Fixtures::CheckedColor.new
    result = instance.call
    check(instance.checks == 2, "expected 2 validator runs, got #{instance.checks.inspect}")
    check(result.word.match?(/\A[a-z]+\z/), "word was #{result.word.inspect}")
    "second answer: #{result.word}"
  }),
  Scenario.new("squawk reports the model and, on macOS 26.4+, token counts", lambda {
    calls = []
    hook = ->(output:, metadata:, error:) { calls << { output:, metadata:, error: } }
    klass = Class.new(Fixtures::Reviewer) { squishling squawk: hook }
    klass.call(review: REVIEW)
    metadata = calls.first[:metadata]
    check(calls.size == 1 && calls.first[:error].nil?, "unexpected squawk calls: #{calls.inspect}")
    check(metadata[:model] == "apple-foundation-model", "model was #{metadata[:model].inspect}")
    check(metadata[:usage].nil? || metadata[:usage].values.all?(Integer), "usage was #{metadata[:usage].inspect}")
    "usage #{metadata[:usage].inspect}"
  }),
  Scenario.new("squishsum takes two concurrent samples, one helper process each", lambda {
    klass = Class.new(Fixtures::Reviewer) { squishling harness: { type: :squishsum, compare: ->(*) { true } } }
    result = klass.call(review: REVIEW)
    check(result.squished?, "expected an LLM result")
    "sample accepted: #{result.sentiment}"
  }),
  Scenario.new("an input over the context window is an LLMError (and does reach the fallback)", lambda {
    begin
      Fixtures::Reviewer.call(review: "word " * 6000)
    rescue Squishling::LLMError => e
      check(e.message.include?("context window"), "unexpected message: #{e.message}")
    else
      raise "expected an LLMError"
    end
    result = Class.new(Fixtures::Fallback).call(text: "word " * 6000)
    check(result.word == "fallback", "the fallback didn't run: #{result.to_h.inspect}")
    "LLMError names the context window; the fallback took over"
  }),
  Scenario.new("a param the model has no use for is a ConfigurationError, not a fallback", lambda {
    klass = Class.new(Fixtures::Fallback) { squishling params: { top_p: 0.5 } }
    begin
      result = klass.call
    rescue Squishling::ConfigurationError => e
      check(e.message.include?("takes only the temperature and max_output_tokens"), "unexpected message: #{e.message}")
      next "rejected top_p"
    end
    raise "expected ConfigurationError, got #{result.to_h.inspect}"
  }),
  Scenario.new("a max_output_tokens of 0 or less is a ConfigurationError, never a reported cutoff", lambda {
    [0, -5].each do |limit|
      klass = Class.new(Fixtures::Reviewer) { squishling params: { max_output_tokens: limit } }
      begin
        result = klass.call(review: REVIEW)
      rescue Squishling::ConfigurationError => e
        check(e.message.include?("max_output_tokens param must be"), "unexpected message: #{e.message}")
        next
      end
      raise "expected ConfigurationError for #{limit}, got #{result.to_h.inspect}"
    end
    "rejected max_output_tokens 0 and -5"
  }),
  Scenario.new("Squishling.verify! accepts the squished classes with the adapter configured", lambda {
    report = Squishling.verify!(Fixtures::Reviewer, Fixtures::InvoiceReader, Fixtures::RawNullable,
      Fixtures::CheckedColor, Fixtures::Fallback)
    check(report.ok?, "verification failed: #{report}")
    "#{report.size} problems"
  }),
  Scenario.new("adapter options come from a Hash, and a bad option fails at setup", lambda {
    begin
      Squishling.configure { |config| config.adapter = { type: :apple_fm, timeout: 60 } }
      check(Fixtures::Reviewer.call(review: REVIEW).squished?, "expected an LLM result with timeout: 60")
      {
        { type: :apple_fm, timeout: -1 } => "must be a positive number",
        { type: :apple_fm, bogus: 1 } => "doesn't take bogus"
      }.each do |options, message|
        error = begin
          Squishling.configure { |config| config.adapter = options }
          nil
        rescue Squishling::ConfigurationError => e
          e
        end
        check(error&.message&.include?(message), "#{options.inspect} gave #{error.inspect}")
      end
    ensure
      Squishling.configure { |config| config.adapter = :apple_fm }
    end
    "timeout: 60 ran; timeout: -1 and an unknown option were rejected"
  }),
  Scenario.new("max_output_tokens that cuts a reply short is reported as a cutoff, not a wrong answer", lambda {
    klass = Class.new(Fixtures::Reviewer) { squishling params: { max_output_tokens: 5 } }
    begin
      klass.call(review: REVIEW)
    rescue Squishling::InvalidOutputError => e
      check(e.truncated?, "expected truncated?, got finish_reason #{e.finish_reason.inspect}")
      next "InvalidOutputError#truncated? (#{e.finish_reason.inspect})"
    end
    raise "expected an InvalidOutputError"
  }),
  Scenario.new("non-ASCII text goes in and comes out as valid UTF-8", lambda {
    result = Fixtures::Reviewer.call(review: "とても良い。素晴らしい購入でした。Très bien, merci !")
    check(result.sentiment.encoding == Encoding::UTF_8 && result.sentiment.valid_encoding?, "bad encoding")
    check(%w[positive negative neutral].include?(result.sentiment), "sentiment was #{result.sentiment.inspect}")
    "#{result.sentiment} #{result.score}"
  }),
  Scenario.new("the compiled helper is cached: a second adapter on the same cache_dir doesn't rebuild", lambda {
    request = word_request
    Dir.mktmpdir("apple_fm_example") do |dir|
      Squishling::AppleFM::Adapter.new(cache_dir: dir).complete(request)
      binary = Dir.glob(File.join(dir, "**", "helper")).first
      check(binary && File.executable?(binary), "no compiled helper under #{dir}")
      built = File.mtime(binary)
      Squishling::AppleFM::Adapter.new(cache_dir: dir).complete(request)
      check(File.mtime(binary) == built, "the helper was rebuilt")
    end
    "one build, reused"
  }),
  Scenario.new("a helper: path that isn't there is a ConfigurationError", lambda {
    adapter = Squishling::AppleFM::Adapter.new(helper: File.join(Dir.tmpdir, "no-such-apple-fm-helper"))
    begin
      adapter.complete(word_request)
    rescue Squishling::ConfigurationError
      next "rejected"
    end
    raise "expected ConfigurationError"
  })
].freeze

def run(scenario)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  detail = scenario.block.call
  puts "  ✓ #{scenario.name} (#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)}s)" \
       "#{" — #{detail}" if detail.is_a?(String)}"
  true
rescue StandardError => e
  puts "  ✗ #{scenario.name}\n      #{e.class}: #{e.message}"
  false
end

puts "squishling-apple_fm live examples (#{Squishling::AppleFM::VERSION})\n\n"
failures = SCENARIOS.count { |scenario| !run(scenario) }
puts "\n#{SCENARIOS.size - failures}/#{SCENARIOS.size} passed"
exit(failures.zero? ? 0 : 1)
