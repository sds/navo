require 'pathname'
require 'yaml'

module Navo
  # Stores runtime configuration for the application.
  #
  # This is intended to define helper methods for accessing configuration so
  # this logic can be shared amongst the various components of the system.
  class Configuration
    # Name of the configuration file.
    FILE_NAME = '.navo.yaml'

    class << self
      # Loads appropriate configuration file given the current working
      # directory.
      #
      # @return [Navo::Configuration]
      def load_applicable
        current_directory = File.expand_path(Dir.pwd)
        config_file = applicable_config_file(current_directory)

        if config_file
          from_file(config_file)
        else
          raise Errors::ConfigurationMissingError,
                "No configuration file '#{FILE_NAME}' was found in the " \
                "current directory or any ancestor directory.\n\n" \
                "See #{REPO_URL}#configuration for instructions on setting up."
        end
      end

      # Loads a configuration from a file.
      #
      # @return [Navo::Configuration]
      def from_file(config_file)
        options =
          if yaml = YAML.load_file(config_file)
            yaml.to_hash
          else
            {}
          end

        new(options: options, path: config_file)
      end

      private

      # Returns the first valid configuration file found, starting from the
      # current working directory and ascending to ancestor directories.
      #
      # @param directory [String]
      # @return [String, nil]
      def applicable_config_file(directory)
        Pathname.new(directory)
                .enum_for(:ascend)
                .map { |dir| dir + FILE_NAME }
                .find do |config_file|
          config_file if config_file.exist?
        end
      end
    end

    # Creates a configuration from the given options hash.
    #
    # @param options [Hash]
    def initialize(options:, path:)
      @options = options
      @path = path
    end

    # Returns the root of the repository to which this configuration applies.
    #
    # @return [String]
    def repo_root
      File.dirname(@path)
    end

    # Access the configuration as if it were a hash.
    #
    # @param key [String, Symbol]
    # @return [Array, Hash, Number, String, Symbol]
    def [](key)
      @options[key.to_s]
    end

    # Set the configuration as if it were a hash.
    #
    # @param key [String, Symbol]
    # @param value [Array, Hash, Number, String, Symbol]
    # @return [Array, Hash, Number, String]
    def []=(key, value)
      @options[key.to_s] = value
    end

    # Access the configuration as if it were a hash.
    #
    # @param key [String, Symbol]
    # @return [Array, Hash, Number, String]
    def fetch(key, *args)
      @options.fetch(key.to_s, *args)
    end

    # Compares this configuration with another.
    #
    # @param other [HamlLint::Configuration]
    # @return [true,false] whether the given configuration is equivalent
    def ==(other)
      super || @options == other.instance_variable_get('@options')
    end
  end
end
