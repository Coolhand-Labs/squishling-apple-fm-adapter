# frozen_string_literal: true

# Live tests: Squishling scenarios through the :apple_fm adapter, on the on-device model built into macOS. No API key,
# no network, no cost. Needs macOS 26 or later on Apple Silicon with Apple Intelligence on, and Xcode or its Command
# Line Tools (the first run compiles the Swift helper, a few seconds). The model has a 4096-token context window.
#
# The scenarios check what the adapter does (typed results, nullable fields, multi-turn retries, token usage, concurrent
# samples, error mapping), not how well a small model answers, so they assert on shapes and types rather than on exact
# answers. Run: bundle exec ruby examples/apple_fm_example.rb
# Exits 0 when every scenario passes, 1 otherwise (including on a Mac that can't run Apple Intelligence).

require "bundler/setup"
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
