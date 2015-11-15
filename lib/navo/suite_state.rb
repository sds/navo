require 'fileutils'
require 'yaml'

module Navo
  # Stores persisted state about a test suite.
  #
  # This allows information to carry forward between different invocations of
  # the tool, e.g. remembering a previously-started Docker container.
  class SuiteState
    FILE_NAME = 'state.yaml'

    def initialize(suite:)
      @suite = suite
    end

    # Access the state as if it were a hash.
    #
    # @param key [String, Symbol]
    # @return [Array, Hash, Number, String]
    def [](key)
      @hash[key.to_s]
    end

    # Set the state as if it were a hash.
    #
    # @param key [String, Symbol]
    # @param value [Array, Hash, Number, String]
    def []=(key, value)
      @hash[key.to_s] = value
    end

    # Loads persisted state.
    def load
      @hash =
        if File.exist?(file_path) && yaml = YAML.load_file(file_path)
          yaml.to_hash
        else
          {} # Handle empty files
        end
    end

    # Persists state to disk.
    def save
      File.open(file_path, 'w') { |f| f.write(@hash.to_yaml) }
    end

    # Destroy persisted state.
    def destroy
      @hash = {}
      FileUtils.rm_f(file_path)
    end

    private

    def file_path
      File.join(@suite.storage_directory, FILE_NAME)
    end
  end
end
