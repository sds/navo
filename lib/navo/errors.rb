# Collection of errors that can be thrown by the application.
module Navo::Errors
  # Base class for all errors reported by this tool.
  class NavoError < StandardError; end

  # Raised when a command on a container fails.
  class ExecutionError < NavoError; end

  # Base class for all configuration-related errors.
  class ConfigurationError < NavoError; end

  # Raised when a configuration file is not present.
  class ConfigurationMissingError < ConfigurationError; end
end
