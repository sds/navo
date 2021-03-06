require 'digest'
require 'fileutils'
require 'logger'

module Navo
  # Manages the display of output and writing of log files.
  #
  # The goal is to make the tool easier to read when running from the command
  # line, but preserving all useful information in log files as well so in-depth
  # debugging can be performed.
  #
  # Each test suite creates its own {Output} instance to write to so individual
  # log lines go to their own files, but they all share a common destination
  # that is synchronized when writing to stdout/stderr for the application as a
  # whole.
  class Logger
    UI_COLORS = {
      unknown: 35, # purple
      fatal: 31,   # red
      error: 31,   # red
      warn: 33,    # yellow
      info: nil,   # normal
      debug: 90,   # gray
    }

    class << self
      attr_reader :logger

      attr_reader :level

      attr_reader :mutex

      def output=(out)
        @logger = ::Logger.new(out)
        @mutex = Mutex.new
      end

      def level=(level)
        level = level ? ::Logger.const_get(level.upcase) : ::Logger::INFO
        @level = level
        @logger.level = level
      end
    end

    def initialize(config:, suite: nil)
      @suite = suite
      @config = config

      if suite
        log_file = File.open(suite.log_file, File::CREAT | File::WRONLY | File::TRUNC)
        @logger = ::Logger.new(log_file)
        @logger.level = ::Logger::DEBUG # Record everything in case we need to inspect later
      end

      @color_hash = {}
    end

    def console(message, severity: :info, flush: true)
      severity_level = ::Logger.const_get(severity.upcase)
      if severity_level >= self.class.level
        self.class.mutex.synchronize do
          self.class.logger << pretty_message(severity, message)
        end
      end
    end

    def log(severity, message, flush: true)
      level = ::Logger.const_get(severity.upcase)
      @logger.add(level, message.chomp("\n")) if @logger
      console(message, severity: severity, flush: flush)
    end

    %i[unknown fatal error warn info debug].each do |severity|
      define_method severity do |msg|
        log(severity, msg, flush: true)
      end
    end

    # Abuse the "unknown" severity to show events. This way we can set the
    # log-level to "error" but still see major events.
    def event(msg)
      unknown("=====> #{msg}")
    end

    def close
      @logger.close if @logger
    end

    private

    def pretty_message(severity, message)
      color_code = UI_COLORS[severity]

      prefix = "[#{@suite.name}] " if @suite
      colored_prefix = "\e[#{color_for_string(@suite.name)}m#{prefix}\e[0m" if prefix
      message = message.to_s
      message = "\e[#{color_code}m#{message}\e[0m" if color_code

      message = indent_output(prefix, colored_prefix, "#{colored_prefix}#{message}")
      message += "\n" unless message.end_with?("\n")
      message
    end

    # Returns a deterministic color code for the given string.
    def color_for_string(string)
      @color_hash[string] ||= (Digest::MD5.hexdigest(string)[0..8].to_i(16) % 6) + 31
    end

    def indent_output(prefix, colored_prefix, message)
      return message unless prefix
      message.gsub(/\n(?!$)/, "\n#{colored_prefix}")
    end
  end
end
