require 'fileutils'
require 'monitor'
require 'yaml'

module Navo
  # Stores persisted state.
  #
  # This allows information to carry forward between different invocations of
  # the tool, e.g. remembering a previously-started Docker container.
  class StateFile
    def initialize(file:, logger:)
      @file = file
      @logger = logger
      @mutex = Monitor.new
    end

    # Access the state as if it were a hash.
    #
    # @param key [String, Symbol]
    # @return [Array, Hash, Number, String]
    def [](key)
      @mutex.synchronize do
        @hash[key.to_s]
      end
    end

    # Set the state as if it were a hash.
    #
    # @param key [String, Symbol]
    # @param value [Array, Hash, Number, String]
    def []=(key, value)
      @mutex.synchronize do
        @hash[key.to_s] = value
        save unless @modifying
        value
      end
    end

    def modify(&block)
      @mutex.synchronize do
        @modifying = true
        begin
          result = block.call(self)
          save
          result
        ensure
          @modifying = false
        end
      end
    end

    # Loads persisted state.
    def load
      @hash =
        if File.exist?(@file) && yaml = YAML.load_file(@file)
          @logger.debug "Loading state from #{@file}"
          yaml.to_hash
        else
          @logger.debug "No state file #{@file} exists; assuming empty state"
          {} # Handle empty files
        end
    end

    # Persists state to disk.
    def save
      @logger.debug "Saving state to #{@file}"
      File.open(@file, 'w') { |f| f.write(@hash.to_yaml) }
    end

    # Destroy persisted state.
    def destroy
      @logger.debug "Removing state from #{@file}"
      @hash = {}
      FileUtils.rm_f(@file)
    end
  end
end
