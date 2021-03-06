require 'fileutils'
require 'pathname'

module Navo
  # Manages the creation and maintenance of the test suite sandbox.
  #
  # The sandbox is just a directory that contains the files and configuration
  # needed to run a test within the suite's container. A temporary directory on
  # the host is maintained
  class Sandbox
    def initialize(suite:, logger:)
      @suite = suite
      @logger = logger
    end

    def update_chef_config
      install_cookbooks
      install_chef_config
    end

    def update_test_config
      test_files_dir = File.join(@suite.repo_root, %w[test integration])
      suite_dir = File.join(test_files_dir, @suite.name)

      unless File.exist?(suite_dir)
        @logger.warn "No test files found at #{suite_dir} for #{@suite.name} suite"
        return
      end

      # serverspec, bats, etc.
      frameworks = Pathname.new(suite_dir).children
                                          .select(&:directory?)
                                          .map(&:basename)
                                          .map(&:to_s)

      suites_directory = File.join(@suite.busser_directory, 'suites')
      @suite.exec!(%w[mkdir -p] + [suites_directory])

      frameworks.each do |framework|
        host_framework_dir = File.join(suite_dir, framework)
        container_framework_dir = File.join(suites_directory, framework)

        @suite.exec!(%w[rm -rf] + [container_framework_dir])

        # In order to work with Busser, we need to copy the helper files into
        # the same directory as the suite's spec files. This avoids issues with
        # symlinks not matching up due to differences in directory structure
        # between host and container (test-kitchen does the same thing).
        helpers_directory = File.join(test_files_dir, 'helpers', framework)
        if File.directory?(helpers_directory)
          @logger.info "Transferring #{framework} test suite helpers..."
          @suite.copy(from: File.join(helpers_directory, '.'),
                      to: container_framework_dir)
        end

        @logger.info "Transferring #{framework} tests..."
        @suite.copy(from: File.join(host_framework_dir, '.'),
                    to: container_framework_dir)
      end

    end

    private

    def install_cookbooks
      @suite.exec!(%w[mkdir -p] + [@suite.chef_config_dir, @suite.chef_run_dir])

      host_cookbooks_dir = File.join(@suite.repo_root, 'cookbooks')
      container_cookbooks_dir = File.join(@suite.chef_run_dir, 'cookbooks')

      Navo.synchronize do
        Berksfile.load

        # Check all files first so we calculate the hashes
        berksfile_changed = @suite.path_changed?(Berksfile.path)
        lockfile_changed = @suite.path_changed?(Berksfile.lockfile_path)
        cookbooks_changed = @suite.path_changed?(host_cookbooks_dir)

        if (berksfile_changed || lockfile_changed || cookbooks_changed) ||
           @suite.path_changed?(Berksfile.vendor_directory)

          @logger.info 'Vendoring cookbooks...'
          Berksfile.vendor(logger: @logger)
          # Recalculate new hash
          @suite.path_changed?(Berksfile.vendor_directory)
        else
          @logger.info 'No cookbooks changed; nothing new to install'
        end
      end
    end

    def install_chef_config
      secret_file = File.expand_path(@suite['chef']['secret'], @suite.repo_root)
      secret_file_basename = File.basename(secret_file)
      @logger.info "Preparing #{secret_file_basename}"
      @suite.copy_if_changed(from: secret_file,
                             to: File.join(@suite.chef_config_dir, secret_file_basename))

      @logger.info 'Preparing solo.rb'
      @suite.write(file: File.join(@suite.chef_config_dir, 'solo.rb'),
                   content: @suite.chef_solo_config)
      @logger.info 'Preparing first-boot.json'
      @suite.write(file: File.join(@suite.chef_config_dir, 'first-boot.json'),
                   content: @suite.node_attributes.to_json)

      @logger.debug 'Installing custom formatter'
      formatter_file = File.expand_path('chef_formatter.rb', File.dirname(__FILE__))
      @suite.copy(from: formatter_file, to: @suite.chef_config_dir)
    end

    def storage_directory
      @storage_directory ||=
        @suite.storage_directory.tap do |path|
          @logger.debug("Ensuring storage directory #{path} exists")
          FileUtils.mkdir_p(path)
        end
    end
  end
end
