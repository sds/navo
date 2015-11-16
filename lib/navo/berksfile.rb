module Navo
  # A global Berksfile to be shared amongst all threads.
  #
  # This synchronizes access so we don't have multiple threads doing the same
  # work resolving cookbooks.
  class Berksfile
    class << self
      attr_accessor :path

      def install(logger: nil)
        Navo.synchronize do
          if @installed
            logger.info 'Berksfile cookbooks already resolved'
            return
          end

          logger.info 'Resolving Berksfile...'
          require 'berkshelf' # Lazily require so we don't have to load for every command
          Berkshelf.logger = Celluloid.logger = logger
          Berkshelf.ui.mute { Berkshelf::Installer.new(berksfile).run }
          Celluloid.logger = nil # Ignore annoying shutdown messages

          @installed = true
        end
      end

      def vendor(suite:, directory:)
        Dir.mktmpdir('navo-berks') do |tmpdir|
          Berkshelf.ui.mute { berksfile.vendor(tmpdir) }
          suite.copy(from: tmpdir, to: directory)
        end
      end

      def cache_directory
        Berkshelf::CookbookStore.default_path
      end

      private

      def berksfile
        @berksfile ||= Berkshelf::Berksfile.from_file(@path)
      end
    end
  end
end
