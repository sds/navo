require 'docker'
require 'digest'
require 'json'
require 'shellwords'

module Navo
  # A test suite.
  class Suite
    attr_reader :name

    def initialize(name:, config:)
      @name = name
      @config = config
      @logger = Navo::Logger.new(suite: self)
    end

    def repo_root
      @config.repo_root
    end

    def [](key)
      @config[key.to_s]
    end

    def fetch(key, *args)
      @config.fetch(key.to_s, *args)
    end

    def chef_config_dir
      '/etc/chef'
    end

    def chef_run_dir
      '/var/chef'
    end

    # Copy file/directory from host to container.
    def copy(from:, to:)
      @logger.debug("Copying file #{from} on host to file #{to} in container")
      system("docker cp #{from} #{container.id}:#{to}")
    end

    # Write contents to a file on the container.
    def write(file:, content:)
      @logger.debug("Writing content #{content.inspect} to file #{file} in container")
      container.exec(%w[bash -c] + ["cat > #{file}"], stdin: StringIO.new(content))
    end

    # Execte a command on the container.
    def exec(args, severity: :debug)
      container.exec(args) do |_stream, chunk|
        @logger.log(severity, chunk, flush: chunk.end_with?("\n"))
      end
    end

    # Execute a command on the container, raising an error if it exists
    # unsuccessfully.
    def exec!(args, severity: :debug)
      out, err, status = exec(args, severity: severity)
      raise Error::ExecutionError, "STDOUT:#{out}\nSTDERR:#{err}" unless status == 0
      [out, err, status]
    end

    def login
      Kernel.exec('docker', 'exec', '-it', container.id, *@config['docker']['shell-command'])
    end

    def chef_solo_config
      return <<-CONF
      node_name #{name.inspect}
      environment #{@config['chef']['environment'].inspect}
      file_cache_path #{File.join(chef_run_dir, 'cache').inspect}
      file_backup_path #{File.join(chef_run_dir, 'backup').inspect}
      cookbook_path #{File.join(chef_run_dir, 'cookbooks').inspect}
      data_bag_path #{File.join(chef_run_dir, 'data_bags').inspect}
      environment_path #{File.join(chef_run_dir, 'environments').inspect}
      role_path #{File.join(chef_run_dir, 'roles').inspect}
      encrypted_data_bag_secret #{File.join(chef_config_dir, 'encrypted_data_bag_secret').inspect}
      CONF
    end

    def node_attributes
      suite_config = @config['suites'][name]
      @config['chef']['attributes']
        .merge(suite_config.fetch('attributes', {}))
        .merge(run_list: suite_config['run-list'])
    end

    def create
      @logger.info "=====> Creating #{name}"
      container
    end

    def converge
      create

      @logger.info "=====> Converging #{name}"
      sandbox.update_chef_config

      _, _, status = exec(%W[
        /opt/chef/embedded/bin/chef-solo
        --config=#{File.join(chef_config_dir, 'solo.rb')}
        --json-attributes=#{File.join(chef_config_dir, 'first-boot.json')}
        --force-formatter
        --no-color
      ], severity: :info)

      state['converged'] = status == 0
      state.save
      state['converged']
    end

    def verify
      create

      @logger.info "=====> Verifying #{name}"
      sandbox.update_test_config

      _, _, status = exec(['/usr/bin/env'] + busser_env + %W[#{busser_bin} test],
                          severity: :info)
      status == 0
    end

    def test
      return false unless converge
      verify
    end

    def destroy
      @logger.info "=====> Destroying #{name}"

      if state['container']
        if @config['docker']['stop-command']
          @logger.info "Stopping container via command #{@config['docker']['stop-command']}"
          exec(@config['docker']['stop-command'])
          container.wait(@config['docker'].fetch('stop-timeout', 10))
        else
          @logger.info "Stopping container..."
          container.stop
        end

        begin
          @logger.info('Removing container')
          container.remove(force: true)
        rescue Docker::Error::ServerError => ex
          @logger.warn ex.message
        end
      end

      state['converged'] = false
      state['container'] = nil
      state.save
    end

    # Returns the {Docker::Image} used by this test suite, building it if
    # necessary.
    #
    # @return [Docker::Image]
    def image
     @image ||=
       begin
         state['images'] ||= {}

         # Build directory is wherever the Dockerfile is located
         dockerfile = File.expand_path(@config['docker']['dockerfile'], repo_root)
         build_dir = File.dirname(dockerfile)

         dockerfile_hash = Digest::SHA256.new.hexdigest(File.read(dockerfile))
         @logger.debug "Dockerfile hash is #{dockerfile_hash}"
         image_id = state['images'][dockerfile_hash]

         if image_id && Docker::Image.exist?(image_id)
           @logger.debug "Previous image #{image_id} matching Dockerfile already exists"
           @logger.debug "Using image #{image_id} instead of building new image"
           Docker::Image.get(image_id)
         else
           @logger.debug "No image exists for #{dockerfile}"
           @logger.debug "Building a new image with #{dockerfile} " \
                         "using #{build_dir} as build context directory"

           Docker::Image.build_from_dir(build_dir) do |chunk|
             if (log = JSON.parse(chunk)) && log.has_key?('stream')
               @logger.info log['stream']
             end
           end.tap do |image|
             state['images'][dockerfile_hash] = image.id
             state.save
           end
         end
       end
    end

    # Returns the {Docker::Container} used by this test suite, starting it if
    # necessary.
    #
    # @return [Docker::Container]
    def container
      @container ||=
        begin
          # Dummy reference so we build the image first (ensuring its log output
          # appears before the container creation log output)
          image

          if state['container']
            begin
              container = Docker::Container.get(state['container'])
              @logger.debug "Loaded existing container #{container.id}"
            rescue Docker::Error::NotFoundError
              @logger.debug "Container #{state['container']} no longer exists"
            end
          end

          if !container
            @logger.info "Building a new container from image #{image.id}"

            container = Docker::Container.create(
              'Image' => image.id,
              'OpenStdin' => true,
              'StdinOnce' => true,
              'HostConfig' => {
                'Privileged' => @config['docker']['privileged'],
                'Binds' => @config['docker']['volumes'],
              },
            )

            state['container'] = container.id
            state.save
          end

          unless started?(container.id)
            @logger.info "Starting container #{container.id}"
            container.start
            container.start
          else
            @logger.debug "Container #{container.id} already running"
          end

          container
        end
    end

    def started?(container_id)
      # There does not appear to be a simple "status" API we can use for an
      # individual container
      Docker::Container.all(all: true,
                            filters: { id: [container_id],
                            status: ['running'] }.to_json).any?
    end

    def sandbox
      @sandbox ||= Sandbox.new(suite: self, logger: @logger)
    end

    def storage_directory
      @storage_directory ||=
        File.join(repo_root, '.navo', 'suites', name).tap do |path|
          FileUtils.mkdir_p(path)
        end
    end

    def busser_directory
      '/tmp/busser'
    end

    def busser_bin
      File.join(busser_directory, %w[gems bin busser])
    end

    def busser_env
      %W[
        BUSSER_ROOT=#{busser_directory}
        GEM_HOME=#{File.join(busser_directory, 'gems')}
        GEM_PATH=#{File.join(busser_directory, 'gems')}
        GEM_CACHE=#{File.join(busser_directory, %w[gems cache])}
      ]
    end

    def state
      @state ||= SuiteState.new(suite: self, logger: @logger).tap(&:load)
    end

    def log_file
      @log_file ||= File.join(storage_directory, 'log.log')
    end
  end
end
