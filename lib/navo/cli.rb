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
      Navo::Logger.level = config['log_level']
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
      option 'summary',
             aliases: '-s',
             type: :boolean,
             desc: 'Print out logs at the end of the run ' \
                   '(best if combined with --log-level=error)'

      if action == :test
        option 'destroy',
               aliases: '-d',
               type: :string,
               desc: 'Destroy strategy to use after testing (passing, always, never)'
      end

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
      @logger ||= Navo::Logger.new(config: config)
    end

    def suites_for(pattern)
      suite_names = config['suites'].keys
      suite_names.select! { |name| name =~ /#{pattern}/ } if pattern

      suite_names.map do |suite_name|
        Suite.new(name: suite_name, config: config, global_state: @global_state)
      end
    end

    def apply_flags_to_config!
      config['log_level'] = options['log-level'] if options['log-level']
      Navo::Logger.level = config['log_level']
      config['concurrency'] = options['concurrency'] if options['concurrency']
      config['destroy'] = options.fetch('destroy', 'passing')
      config['summary'] = options.fetch('summary', false)

      # Initialize here so config is correctly set
      Berksfile.path = File.expand_path(config['chef']['berksfile'], config.repo_root)
      Berksfile.config = config
      @global_state = StateFile.new(file: File.join(config.repo_root, %w[.navo global-state.yaml]),
                                    logger: logger).tap(&:load)
    end

    def execute(action, pattern = nil)
      suites = suites_for(pattern)

      verbing = action.to_s.end_with?('e') ? "#{action.to_s[0..-2]}ing" : "#{action}ing"

      if pattern
        if suites.count > 1
          logger.event "#{verbing.capitalize} #{suites.count} suites:"
          suites.each do |suite|
            logger.event suite.name
          end
        elsif suites.count < 1
          logger.fatal "No suites matching pattern '#{pattern}'!"
          exit 1
        end
      elsif suites.count > 0
        logger.event "#{verbing.capitalize} all #{suites.count} suites"
      else
        logger.fatal 'No suites defined!'
        exit 1
      end

      results = Parallel.map(suites, in_threads: config['concurrency']) do |suite|
        succeeded =
          begin
            suite.send(action)
          rescue => err
            suite.logger.fatal("#{err.class}: #{err.message}")
            suite.logger.fatal(err.backtrace.join("\n"))
            false
          end
        suite.close_log
        [succeeded, suite]
      end

      failures = results.reject { |succeeded, result, _| succeeded }

      if config['summary']
        failures.each do |_, suite|
          logger.event("LOG OUTPUT FOR `#{suite.name}`:")
          puts File.read(suite.log_file)
        end
      end

      failures.each do |_, suite, err|
        logger.error("`#{action}` failed for suite `#{suite.name}`")
        logger.error("See #{suite.log_file} for full `#{suite.name}` log output")
      end

      exit failures.any? ? 1 : 0
    rescue Interrupt
      # Handle Ctrl-C
      logger.fatal('INTERRUPTED')
    rescue => ex
      logger.fatal("#{ex.class}: #{ex.message}")
      logger.fatal(ex.backtrace.join("\n"))
    end
  end
end
