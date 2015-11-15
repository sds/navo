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
      fatal: 39,   # hot red
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

    def initialize(suite: nil)
      @suite = suite

      if suite
        log_file = File.open(suite.log_file, File::CREAT | File::WRONLY | File::APPEND)
        @logger = ::Logger.new(log_file)
        @logger.level = self.class.level
      end
    end

    def log(severity, message)
      level = ::Logger.const_get(severity.upcase)
      @logger.add(level, message)

      color_code = UI_COLORS[severity]
      prefix = @suite ? "[#{@suite.name}] " : ""
      message = "\e[#{color_code}m#{message}\e[0m" if color_code
      message += "\n" unless message.end_with?("\n")

      # This is shared amongst potentially many threads, so serialize access
      self.class.mutex.synchronize do
        self.class.logger << "#{prefix}#{message}"
      end
    end

    %i[unknown fatal error warn info debug].each do |severity|
      define_method severity do |msg|
        log(severity, msg)
      end
    end
  end
end
