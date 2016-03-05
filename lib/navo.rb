require 'navo/constants'
require 'navo/errors'
require 'navo/configuration'
require 'navo/logger'
require 'navo/sandbox'
require 'navo/suite'
require 'navo/berksfile'
require 'navo/state_file'
require 'navo/utils'
require 'navo/version'

module Navo
  class << self
    attr_accessor :mutex

    # Synchronize access. If a key is specified, synchronizes access for that
    # key. This allows us to ensure only one thread modifies a particular
    # resource (say building a particular Dockerfile).
    def synchronize(key = nil)
      mutex[key].synchronize do
        yield
      end
    end
  end
end

Navo.mutex = Hash.new { |h, k| h[k] = Mutex.new }

Excon.defaults[:read_timeout] = 600
