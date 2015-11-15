require 'berkshelf'
require 'fileutils'
require 'pathname'

module Navo
  # Manages the creation and maintenance of the test suite sandbox.
  #
  # The sandbox is just a directory that contains the files and configuration
  # needed to run a test within the suite's container. A temporary directory on
  # the host is maintained
  class Sandbox
    def initialize(suite:)
      @suite = suite
    end

    def update_chef_config
      install_cookbooks
      install_chef_directories
      install_chef_config
    end

    def update_test_config
      test_files_dir = File.join(@suite.repo_root, %w[test integration])
      suite_dir = File.join(test_files_dir, @suite.name)

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
          puts "Transferring #{framework} test suite helpers..."
          @suite.copy(from: File.join(helpers_directory, '.'),
                      to: container_framework_dir)
        end

        puts "Transferring #{framework} tests..."
        @suite.copy(from: File.join(host_framework_dir, '.'),
                    to: container_framework_dir)
      end

    end

    private

    def install_cookbooks
      @suite.exec!(%w[mkdir -p] + [@suite.chef_config_dir, @suite.chef_run_dir])

      vendored_cookbooks_dir = File.join(storage_directory, 'cookbooks')
      berksfile = File.expand_path(@suite['chef']['berksfile'], @suite.repo_root)

      puts 'Resolving Berksfile...'
      @suite.exec!(%w[rm -rf] + [vendored_cookbooks_dir])
      Berkshelf::Berksfile.from_file(berksfile).vendor(vendored_cookbooks_dir)

      @suite.copy(from: File.join(storage_directory, 'cookbooks', '.'),
                  to: File.join(@suite.chef_run_dir, 'cookbooks'))
    end

    def install_chef_directories
      %w[data_bags environments roles].each do |dir|
        puts "Preparing #{dir} directory..."
        host_dir = File.join(@suite.repo_root, dir)
        container_dir = File.join(@suite.chef_run_dir, dir)

        @suite.exec(%w[rm -rf] + [container_dir])
        @suite.copy(from: host_dir, to: container_dir)
      end
    end

    def install_chef_config
      secret_file = File.expand_path(@suite['chef']['secret'], @suite.repo_root)
      secret_file_basename = File.basename(secret_file)
      @suite.copy(from: secret_file,
                  to: File.join(@suite.chef_config_dir, secret_file_basename))

      puts 'Preparing solo.rb'
      @suite.write(file: File.join(@suite.chef_config_dir, 'solo.rb'),
                   content: @suite.chef_solo_config)
      puts 'Preparing first-boot.json'
      @suite.write(file: File.join(@suite.chef_config_dir, 'first-boot.json'),
                   content: @suite.node_attributes.to_json)
    end

    def storage_directory
      @storage_directory ||=
        @suite.storage_directory.tap do |path|
          FileUtils.mkdir_p(path)
        end
    end
  end
end