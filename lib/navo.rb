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

    def synchronize
      mutex.synchronize do
        yield
      end
    end
  end
end

Navo.mutex = Mutex.new

Excon.defaults[:read_timeout] = 600
