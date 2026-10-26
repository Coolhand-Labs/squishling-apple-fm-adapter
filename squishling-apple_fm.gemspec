# frozen_string_literal: true

require_relative "lib/squishling/apple_fm/version"

Gem::Specification.new do |spec|
  spec.name = "squishling-apple_fm"
  spec.version = Squishling::AppleFM::VERSION
  spec.authors = ["Michael Carroll"]
  spec.email = ["mc@coolhandlabs.com"]

  spec.summary = "Squishling adapter for Apple's on-device model (Apple Intelligence): free, offline LLM calls in " \
                 "development."
  spec.description = "A Squishling adapter that runs Ruby LLM calls on the Apple Foundation Models on-device model " \
                     "built into macOS 26 and later (Apple Intelligence): no API key, no network, no cost. Meant " \
                     "for trying Squishling and developing against it locally, then running production on a " \
                     "hosted model. Strict structured output is translated into Apple's guided generation; the " \
                     "framework is Swift-only, so a small bundled Swift helper is compiled with the Xcode " \
                     "toolchain on first use."
  spec.homepage = "https://github.com/Coolhand-Labs/squishling-apple-fm-adapter"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/tree/main/docs"

  # Ship only what's tracked in git, minus development-only files.
  dev_files = %w[AGENTS.md CLAUDE.md]
  dev_prefixes = %w[bin/ test/ spec/ features/ examples/ assets/
                    .git .claude .idea .rubocop .simplecov .rspec Gemfile]
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      File.expand_path(f) == __FILE__ || dev_files.include?(f) || f.start_with?(*dev_prefixes)
    end
  end
  spec.require_paths = ["lib"]

  # The first Squishling with pluggable adapters (Squishling.register_adapter). Raise this to that release's number.
  spec.add_dependency "squishling", ">= 0.4.0"

  spec.metadata["rubygems_mfa_required"] = "true"
end
