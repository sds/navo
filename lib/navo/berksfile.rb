require 'fileutils'

module Navo
  # A global Berksfile to be shared amongst all threads.
  #
  # This synchronizes access so we don't have multiple threads doing the same
  # work resolving cookbooks.
  class Berksfile
    class << self
      attr_accessor :path
      attr_accessor :config

      def load
        require 'berkshelf' # Lazily require so we don't have to load for every command
        berksfile
      end

      def install(logger: nil)
        if @installed
          logger.info 'Berksfile cookbooks already resolved'
          return
        end

        logger.info 'Installing Berksfile...'
        Berkshelf.logger = Celluloid.logger = logger
        Berkshelf.ui.mute { Berkshelf::Installer.new(berksfile).run }
        Celluloid.logger = nil # Ignore annoying shutdown messages

        @installed = true
      end

      def vendor(logger:)
          Berkshelf.logger = Celluloid.logger = logger
          Berkshelf.ui.mute { berksfile.vendor(vendor_directory) }
          Celluloid.logger = nil # Ignore annoying shutdown messages
      end

      def cache_directory
        Berkshelf::CookbookStore.default_path
      end

      def vendor_directory
        @vendor_directory ||=
          FileUtils.mkdir_p(File.join(config.repo_root, %w[.navo vendored-cookbooks])).first
      end

      def lockfile_path
        berksfile.lockfile.filepath
      end

      private

      def berksfile
        @berksfile ||= Berkshelf::Berksfile.from_file(@path)
      end
    end
  end
end
