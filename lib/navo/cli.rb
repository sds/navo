require 'navo'
require 'parallel'
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

    {
      create: 'create a container for test suite(s) to run within',
      converge: 'run Chef for test suite(s)',
      verify: 'run test suites(s)',
      test: 'converge and run test suites(s)',
      destroy: 'clean up test suite(s)',
    }.each do |action, description|
      desc "#{action} [suite|regexp]", description
      option :concurrency,
             aliases: '-c',
             type: :numeric,
             default: Parallel.processor_count,
             desc: 'Execute up to the specified number of test suites concurrently'
      option 'log-level',
             aliases: '-l',
             type: :string,
             desc: 'Set the log output verbosity level'
      define_method(action) do |*args|
        apply_flags_to_config!
        execute(action, *args)
      end
    end

    desc 'login', "open a shell inside a suite's container"
    def login(pattern)
      apply_flags_to_config!

      suites = suites_for(pattern)
      if suites.size == 0
        logger.console "Pattern '#{pattern}' matched no test suites", severity: :error
        exit 1
      elsif suites.size > 1
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
        Suite.new(name: suite_name, config: config, global_state: @global_state)
      end
    end

    def apply_flags_to_config!
      config['log-level'] = options['log-level'] if options['log-level']
      Navo::Logger.level = config['log-level']
      config['concurrency'] = options['concurrency'] if options['concurrency']

      # Initialize here so config is correctly set
      Berksfile.path = File.expand_path(config['chef']['berksfile'], config.repo_root)
      @global_state = StateFile.new(file: File.join(config.repo_root, %w[.navo global-state.yaml]),
                                    logger: logger).tap(&:load)
    end

    def execute(action, pattern = nil)
      suites = suites_for(pattern)
      results = Parallel.map(suites, in_threads: config['concurrency']) do |suite|
        succeeded = suite.send(action)
        [succeeded, suite]
      end

      failures = results.reject { |succeeded, result| succeeded }
      failures.each do |_, suite|
        logger.console("Failed to #{action} #{suite.name}", severity: :error)
        logger.console("See #{suite.log_file} for full log output", severity: :error)
      end

      exit failures.any? ? 1 : 0
    rescue Interrupt
      # Handle Ctrl-C
      logger.console('INTERRUPTED', severity: :warn)
    rescue => ex
      logger.console("Unexpected error: #{ex.message}", severity: :fatal)
      logger.console(ex.backtrace.join("\n"), severity: :fatal)
    end
  end
end
