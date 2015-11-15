require 'berkshelf'
require 'fileutils'
require 'docker'
require 'json'
require 'marina'
require 'tmpdir'
require 'thor'

module Marina
  # Command line application interface.
  class CLI < Thor
    # Set of semantic exit codes we can return.
    #
    # @see http://www.gsp.com/cgi-bin/man.cgi?section=3&topic=sysexits
    module ExitCodes
      OK          = 0   # Successful execution
      USAGE       = 64  # User error (bad command line or invalid input)
      SOFTWARE    = 70  # Internal software error (bug)
      CONFIG      = 78  # Configuration error (invalid file or options)
    end

    desc 'create', 'create a container for test suite(s) to run within'
    def create(pattern = nil)
      suites_for(pattern).each(&:create)
    end

    desc 'converge', 'run Chef for test suite(s)'
    def converge(pattern = nil)
      suites_for(pattern).each(&:converge)
    end

    desc 'test', 'run test suite(s)'
    def test(pattern = nil)
      suites_for(pattern).each(&:test)
    end

    desc 'login', "open a shell inside a suite's container"
    def login(pattern)
      suites = suites_for(pattern)
      if suites.size > 1
        puts 'Pattern matched more than one test suite'
      else
        suites.first.login
      end
    end

    private

    def config
      @config ||= Configuration.load_applicable
    end

    def suites_for(pattern)
      suite_names = config['suites'].keys
      suite_names.select! { |name| name =~ /#{pattern}/ } if pattern

      suite_names.map do |suite_name|
        Suite.new(name: suite_name, config: config)
      end
    end
  end
end
