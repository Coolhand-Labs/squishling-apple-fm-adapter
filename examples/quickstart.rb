# frozen_string_literal: true

# The shortest check that a fresh install works: one Squishling call on the on-device model, with no API key.
# Needs macOS 26+ on Apple Silicon with Apple Intelligence on, and Xcode or its Command Line Tools (the first run
# compiles the Swift helper, a few seconds). Run: bundle exec ruby examples/quickstart.rb

require "bundler/setup"
require "squishling/apple_fm"

Squishling.configure { |config| config.adapter = :apple_fm }

class Reviewer
  include Squishling

  purpose "Classify the sentiment of the product review."
  output_schema { string :sentiment, enum: %w[positive negative neutral] }
end

result = Reviewer.call(review: "Absolutely love it. Best purchase I've made all year.")
puts "sentiment: #{result.sentiment}"
exit(%w[positive negative neutral].include?(result.sentiment) ? 0 : 1)
