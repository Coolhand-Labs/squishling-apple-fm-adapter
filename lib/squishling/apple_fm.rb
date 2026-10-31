# frozen_string_literal: true

require "squishling"

# The squishling-apple_fm adapter registers itself with the pluggable-adapters API, so an older Squishling can't use it.
unless Squishling.respond_to?(:register_adapter)
  raise LoadError, "squishling-apple_fm needs a Squishling release with pluggable adapters " \
                   "(Squishling.register_adapter); you have Squishling #{Squishling::VERSION}. Upgrade squishling."
end

require_relative "apple_fm/version"
require_relative "apple_fm/generation_schema"
require_relative "apple_fm/helper"
require_relative "apple_fm/adapter"

module Squishling
  # Runs Squishling on the on-device model built into macOS (Apple Intelligence). Requiring this gem registers the
  # adapter as :apple_fm; see Squishling::AppleFM::Adapter.
  module AppleFM
    # Registers the adapter under :apple_fm unless it is already there. Called when the gem loads; call it again
    # after Squishling.reset_adapters!, which forgets every adapter that isn't built in.
    def self.register
      Squishling.register_adapter(:apple_fm, Adapter) unless Squishling.adapters.include?(:apple_fm)
    end
  end
end

Squishling::AppleFM.register
