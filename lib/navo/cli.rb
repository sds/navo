require 'navo'
require 'thor'

module Navo
  # Command line application interface.
  class CLI < Thor
    def initialize(*args)
      super
      Navo::Logger.output = STDOUT
      STDOUT.sync = true
      Navo::Logger.level = config['log-level']
    end

    desc 'create', 'create a container for test suite(s) to run within'
    def create(pattern = nil)
      exit suites_for(pattern).map(&:create).all? ? 0 : 1
    end

    desc 'converge', 'run Chef for test suite(s)'
    def converge(pattern = nil)
      exit suites_for(pattern).map(&:converge).all? ? 0 : 1
    end

    desc 'verify', 'run test suite(s)'
    def verify(pattern = nil)
      exit suites_for(pattern).map(&:verify).all? ? 0 : 1
    end

    desc 'test', 'converge and run test suite(s)'
    def test(pattern = nil)
      exit suites_for(pattern).map(&:test).all? ? 0 : 1
    end

    desc 'destroy', 'clean up test suite(s)'
    def destroy(pattern = nil)
      exit suites_for(pattern).map(&:destroy).all? ? 0 : 1
    end

    desc 'login', "open a shell inside a suite's container"
    def login(pattern)
      suites = suites_for(pattern)
      if suites.size > 1
        logger.console "Pattern '#{pattern}' matched more than one test suite", severity: :error
        exit 1
      else
        suites.first.login
      end
    end

    private

    def config
      @config ||= Configuration.load_applicable
    end

    def logger
      @logger ||= Navo::Logger.new
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
