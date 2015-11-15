# Collection of errors that can be thrown by the application.
module Marina::Errors
  # Base class for all errors reported by this tool.
  class MarinaError < StandardError; end

  # Base class for all configuration-related errors.
  class ConfigurationError < MarinaError; end

  # Raised when a configuration file is not present.
  class ConfigurationMissingError < ConfigurationError; end
end
