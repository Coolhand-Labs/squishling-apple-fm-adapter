# frozen_string_literal: true

module Squishling
  module AppleFM
    # Runs requests on the on-device model built into macOS (Apple Intelligence, through the FoundationModels
    # framework): free, offline, and private, so a good fit for developing against Squishling without an API key or a
    # bill. It needs macOS 26 or later on Apple Silicon with Apple Intelligence turned on, and Xcode (or its Command
    # Line Tools) to compile a small Swift helper on first use. No gem, no server, no network. The model is small
    # (a 4096-token context window for the prompt, the schema, and the answer), so expect to develop here and run
    # production on a bigger model. See the README.
    #
    #   Squishling.configure do |config|
    #     config.adapter = :apple_fm
    #   end
    class Adapter < Squishling::Adapter::Base
      # What Response#model reports: the system has one model and doesn't name it.
      MODEL = "apple-foundation-model"
      PORTABLE_PARAMS = %i[temperature max_output_tokens].freeze
      TOKEN_KEYS = %w[input_tokens output_tokens].freeze
      # The helper's error codes. A setup mistake is never retried; the rest depend on the input or the moment, so
      # another attempt may work. Only these texts are used: the system's own message is never repeated.
      SETUP_FAILURES = {
        "device_not_eligible" => "this Mac can't run Apple Intelligence",
        "apple_intelligence_not_enabled" => "turn on Apple Intelligence in System Settings",
        "unsupported_schema" => "the schema uses something the on-device model can't generate",
        "bad_request" => "the helper couldn't read the request"
      }.freeze
      FAILURES = {
        "context_window" => "the prompt, schema, and answer didn't fit the model's 4096-token context window",
        "guardrail" => "the model declined the request (Apple's safety guardrails)",
        "unsupported_language" => "the model doesn't support the language of the request",
        "rate_limited" => "the system rate-limited the request",
        "model_not_ready" => "the on-device model isn't ready yet (it may still be downloading)"
      }.freeze
      private_constant :PORTABLE_PARAMS, :TOKEN_KEYS, :SETUP_FAILURES, :FAILURES

      # timeout: seconds to wait for an answer before giving up (an LLMError). helper: the path of a prebuilt helper
      # to run instead of compiling the bundled one. cache_dir: where compiled helpers are kept (default
      # ~/Library/Caches/squishling/apple_fm, or under $XDG_CACHE_HOME). ignore_unsupported_params: drop the params
      # the system has no use for instead of raising, so a class written for a hosted model runs here unchanged
      # (default false). Raises ConfigurationError for a bad option.
      def initialize(timeout: 120, helper: nil, cache_dir: nil, ignore_unsupported_params: false)
        super()
        invalid(:timeout, "a positive number", timeout) unless timeout.is_a?(Numeric) && timeout.positive?
        unless [true, false].include?(ignore_unsupported_params)
          invalid(:ignore_unsupported_params, "true or false", ignore_unsupported_params)
        end
        @timeout = timeout
        @ignore_unsupported_params = ignore_unsupported_params
        @helper = Helper.new(path: path(:helper, helper), cache_dir: path(:cache_dir, cache_dir))
      end

      def complete(request)
        answer = @helper.call(payload(request), timeout: @timeout)
        if answer["content"].is_a?(String)
          return Squishling::Adapter::Response.new(content: answer["content"], model: MODEL,
            tokens: tokens_of(answer["usage"]), finish_reason: finish_reason_of(answer))
        end

        raise failure(request, answer["error"].to_s)
      rescue Helper::Unavailable => e
        raise configuration_error(request, e.message)
      rescue Helper::Failed => e
        raise llm_error(request, e.message)
      end

      private

      def payload(request)
        { "instructions" => request.instructions, "messages" => messages(request),
          "schema" => GenerationSchema.call(request.schema["schema"]) }.merge(generation_options(request))
      end

      def messages(request)
        request.messages.map { |message| { "role" => message[:role].to_s, "content" => message[:content] } }
      end

      # The system has no reasoning mode and takes no provider-specific params.
      def generation_options(request)
        params = request.params
        reject_unsupported(request, params) unless @ignore_unsupported_params

        { "temperature" => params[:temperature], "max_tokens" => params[:max_output_tokens] }.compact
      end

      # Names only: a param's value never appears in an error.
      def reject_unsupported(request, params)
        unsupported = params.keys - PORTABLE_PARAMS
        unsupported -= [:thinking] unless params[:thinking]
        return if unsupported.empty?

        raise configuration_error(request, "the on-device model takes only the temperature and max_output_tokens " \
                                           "params, not #{unsupported.join(', ')} " \
                                           "(set ignore_unsupported_params: true to drop them)")
      end

      # The helper counts tokens on macOS 26.4 and later; before that it sends none.
      def tokens_of(usage)
        return {} unless usage.is_a?(Hash)

        usage.slice(*TOKEN_KEYS).select { |_, count| count.is_a?(Integer) }.transform_keys(&:to_sym)
      end

      # The helper reports only a reply that max_output_tokens cut off; it has no other reason to give.
      def finish_reason_of(answer)
        :max_tokens if answer["finish_reason"] == "max_tokens"
      end

      def failure(request, code)
        return configuration_error(request, SETUP_FAILURES[code]) if SETUP_FAILURES.key?(code)

        llm_error(request, FAILURES.fetch(code, "the on-device model failed"))
      end

      def path(name, value)
        return nil if value.nil?

        text = value.respond_to?(:to_path) ? value.to_path : value
        return text if text.is_a?(String) && !text.strip.empty?

        invalid(name, "a path", value)
      end

      def invalid(name, expected, value)
        raise ConfigurationError, "adapter :apple_fm #{name} must be #{expected}, got #{value.inspect}"
      end
    end
  end
end
