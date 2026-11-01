# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"

module Squishling
  module AppleFM
    # The small Swift program AppleFM::Adapter talks to. Apple's FoundationModels framework is Swift-only (no C or
    # Objective-C interface), so something Swift has to call it: apple_fm/helper.swift reads one JSON request on stdin
    # and writes one JSON answer on stdout. It is compiled on first use with the swiftc that ships with Xcode or the
    # Command Line Tools, and the binary is cached by the source's digest, so later calls (and later processes) start
    # it directly. A call is one process, so there is no shared state between threads.
    class Helper
      SOURCE = File.join(__dir__, "helper.swift")

      # The helper can't run here (not macOS, no compiler, it won't compile): a setup mistake.
      class Unavailable < StandardError
      end

      # The helper ran but produced no answer (it crashed, or took too long): worth another attempt.
      class Failed < StandardError
      end

      # path: a prebuilt helper to use instead of compiling the bundled source. cache_dir: where compiled helpers go.
      def initialize(path: nil, cache_dir: nil)
        @path = path
        @cache_dir = cache_dir || default_cache_dir
        @build_lock = Mutex.new
      end

      # Sends request (a Hash) and returns the helper's answer (a Hash). Raises Unavailable or Failed.
      def call(request, timeout:)
        command = executable
        payload = JSON.generate(request) # before any process or thread exists, so a failure leaves nothing behind
        # [command, command] is the program and its argv[0], run as given: a bare String with a space or a shell
        # metacharacter in it (a home directory like "/Users/Mary Ann") would be split or handed to /bin/sh.
        Open3.popen2([command, command], err: File::NULL) do |stdin, stdout, wait|
          reader = quiet_thread { stdout.read }
          writer = quiet_thread { send_request(stdin, payload) }
          timed_out = !finished_within?([writer, reader], timeout)
          kill(wait.pid) if timed_out
          answer(timed_out ? nil : reader.value, wait.value, timeout)
        end
      rescue Errno::ENOENT, Errno::EACCES
        raise Unavailable, "the apple_fm helper #{command.inspect} can't be run"
      end

      private

      # The reader starts before the write, and the write runs in a thread of its own: a helper that fills its stdout
      # before it has read all of stdin, or never reads stdin, can't block the call past the timeout. A thread that
      # fails when the pipes are closed under it (the timeout path) reports nothing.
      def quiet_thread
        Thread.new do
          Thread.current.report_on_exception = false
          yield
        end
      end

      # True when every thread finished within timeout seconds in all; the write and the read share that one budget.
      def finished_within?(threads, timeout)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        threads.all? do |thread|
          thread.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
        end
      end

      # The helper may exit on its own between the timeout and the kill.
      def kill(pid)
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end

      def send_request(stdin, payload)
        stdin.write(payload)
      rescue Errno::EPIPE
        nil # the helper already exited; its status explains why
      ensure
        stdin.close
      end

      def answer(output, status, timeout)
        raise Failed, "the helper took longer than #{timeout}s" if output.nil?

        parsed = JSON.parse(output.to_s.dup.force_encoding(Encoding::UTF_8))
        return parsed if parsed.is_a?(Hash)

        raise Failed, "the helper answered with something other than a JSON object"
      rescue JSON::ParserError
        raise Failed, "the helper produced no answer (#{describe(status)})"
      end

      def describe(status)
        status.signaled? ? "signal #{status.termsig}" : "exit #{status.exitstatus}"
      end

      # Built once per process, and again if the cache was cleared since.
      def executable
        @build_lock.synchronize do
          @executable = nil unless @executable && File.executable?(@executable)
          @executable ||= @path || build
        end
      end

      def build
        unless RUBY_PLATFORM.include?("darwin")
          raise Unavailable, "Apple's on-device model needs macOS 26 or later on Apple Silicon"
        end

        target = File.join(@cache_dir, Digest::SHA256.file(SOURCE).hexdigest[0, 16], "helper")
        compile(target) unless File.executable?(target)
        target
      end

      # Compiled to a temporary name and renamed into place, under a file lock so that concurrent processes build
      # once and none runs a half-written binary. The directories it creates are private to the user: the binary's
      # path is predictable (the source's digest), so nobody else may be able to put a file there.
      def compile(target)
        FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
        File.open("#{target}.lock", File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          next if File.executable?(target)

          temporary = "#{target}.#{Process.pid}.tmp"
          swiftc(temporary)
          File.rename(temporary, target)
        end
      rescue SystemCallError
        raise Unavailable, "the apple_fm helper can't be built in #{@cache_dir.inspect}; give the adapter a writable " \
                           "cache_dir:"
      end

      def swiftc(output)
        command = ["swiftc", "-O", SOURCE, "-o", output]
        _, status = Open3.capture2e(*command)
        return if status.success?

        FileUtils.rm_f(output)
        raise Unavailable, "compiling the apple_fm helper failed; run `#{command.join(' ')}` to see why " \
                           "(it needs Xcode 26 or later, or its Command Line Tools)"
      rescue Errno::ENOENT
        raise Unavailable, "swiftc wasn't found; install Xcode or run `xcode-select --install`"
      end

      # $XDG_CACHE_HOME when it is set and not empty (the XDG spec treats empty as unset), else ~/Library/Caches.
      def default_cache_dir
        base = ENV.fetch("XDG_CACHE_HOME", "").strip
        base = File.join(Dir.home, "Library", "Caches") if base.empty?
        File.join(base, "squishling", "apple_fm")
      end
    end
  end
end
