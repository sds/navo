require 'docker'
require 'digest'
require 'json'
require 'shellwords'

module Navo
  # A test suite.
  class Suite
    attr_reader :name

    attr_reader :logger

    def initialize(name:, config:, global_state:)
      @name = name
      @config = config
      @logger = Navo::Logger.new(config: config, suite: self)
      @global_state = global_state

      state.modify do |local|
        local['files'] ||= {}
      end
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

    def copy_if_changed(from:, to:, replace: false)
      if File.directory?(from)
        exec(%w[mkdir -p] + [to])
      else
        exec(%w[mkdir -p] + [File.dirname(to)])
      end

      current_hash = Utils.path_hash(from)
      state['files'] ||= {}
      old_hash = state['files'][from.to_s]

      if !old_hash || current_hash != old_hash
        if old_hash
          @logger.debug "Previous hash recorded for #{from} (#{old_hash}) " \
                        "does not match current hash (#{current_hash})"
        else
          @logger.debug "No previous hash recorded for #{from}"
        end

        state.modify do |local|
          local['files'][from.to_s] = current_hash
        end

        exec(%w[rm -rf] + [to]) if replace
        copy(from: from, to: to)
        return true
      end

      false
    end

    # TODO: Move to a separate class, since this isn't really suite-specific,
    # but global to the entire repository.
    def path_changed?(path)
      current_hash = Utils.path_hash(path)
      @global_state['files'] ||= {}
      old_hash = @global_state['files'][path.to_s]

      @logger.debug("Old hash of #{path.to_s}: #{old_hash}")
      @logger.debug("Current hash of #{path.to_s}: #{current_hash}")

      @global_state.modify do |local|
        local['files'][path.to_s] = current_hash
      end

      !old_hash || current_hash != old_hash
    end

    # Write contents to a file on the container.
    def write(file:, content:)
      @logger.debug("Writing content #{content.inspect} to file #{file} in container")
      container.exec(%w[bash -c] + ["cat > #{file}"], stdin: StringIO.new(content))
    end

    # Execte a command on the container.
    def exec(args, severity: :debug)
      container.exec(args) do |_stream, chunk|
        @logger.log(severity, chunk, flush: chunk.to_s.end_with?("\n"))
      end
    end

    # Execute a command on the container, raising an error if it exits
    # unsuccessfully.
    def exec!(args, severity: :debug)
      out, err, status = exec(args, severity: severity)
      raise Error::ExecutionError, "STDOUT:#{out}\nSTDERR:#{err}" unless status == 0
      [out, err, status]
    end

    def login
      Kernel.exec('docker', 'exec',
                  "--detach-keys=#{@config.fetch('detach_keys', 'ctrl-x,b')}",
                  '-it', container.id,
                  *@config['docker'].fetch('shell_command', ['/bin/bash']))
    end

    def chef_solo_config
      return <<-CONF
      load '/etc/chef/chef_formatter.rb'
      formatter :navo

      node_name #{hostname.inspect}
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

      unless (run_list = Array(suite_config['run_list'])).any?
        raise Navo::Errors::ConfigurationError,
              "No `run_list` specified for suite #{name}!"
      end

      @config['chef']['attributes']
        .merge(suite_config.fetch('attributes', {}))
        .merge(run_list: suite_config['run_list'])
    end

    def create
      @logger.event "Creating #{name}"
      container
      @logger.event "Created #{name} in container #{container.id}"
      container
    end

    def converge
      create

      @logger.event "Converging #{name}"
      sandbox.update_chef_config

      _, _, status = exec(%W[
        /opt/chef/embedded/bin/chef-solo
        --config=#{File.join(chef_config_dir, 'solo.rb')}
        --json-attributes=#{File.join(chef_config_dir, 'first-boot.json')}
        --format=navo
        --force-formatter
      ], severity: :info)

      status == 0
    end

    def verify
      create

      @logger.event "Verifying #{name}"
      sandbox.update_test_config

      _, _, status = exec(['/usr/bin/env'] + busser_env + %W[#{busser_bin} test],
                          severity: :info)
      status == 0
    end

    def test
      return false unless destroy
      passed = converge && verify

      should_destroy =
        case @config['destroy']
        when 'passing'
          passed
        when 'always'
          true
        when 'never'
          false
        end

      should_destroy ? destroy : passed
    end

    def destroy
      @logger.event "Destroying #{name}"

      if state['container']
        begin
          if @config['docker']['stop_command']
            @logger.info "Stopping container #{container.id} via command #{@config['docker']['stop_command']}"
            exec(@config['docker']['stop_command'])
            container.wait(@config['docker'].fetch('stop_timeout', 10))
          else
            @logger.info "Stopping container #{container.id}..."
            container.stop
          end
        rescue Docker::Error::TimeoutError => ex
          @logger.warn ex.message
        ensure
          begin
            @logger.info("Removing container #{container.id}")
            container.remove(force: true, v: true)
          rescue Docker::Error::ServerError => ex
            @logger.warn ex.message
          end
        end
      end

      true
    ensure
      @container = nil
      state.destroy

      @logger.event "Destroyed #{name}"
    end

    # Returns the {Docker::Image} used by this test suite, building it if
    # necessary.
    #
    # @return [Docker::Image]
    def image
     @image ||=
       begin
         @global_state.modify do |global|
           global['images'] ||= {}
         end

         # Build directory is wherever the Dockerfile is located
         dockerfile = File.expand_path(@config['docker']['dockerfile'], repo_root)
         build_dir = File.dirname(dockerfile)

         image_name = "#{@config['docker'].fetch('repo', 'navo')}:#{name}"
         image = Navo.synchronize(dockerfile) do
           dockerfile_hash = Digest::SHA256.new.hexdigest(File.read(dockerfile))
           @logger.debug "Dockerfile hash is #{dockerfile_hash}"

           image_id = @global_state['images'][dockerfile_hash]

           if image_id && Docker::Image.exist?(image_id)
             @logger.debug "Previous image #{image_id} matching Dockerfile already exists"
             @logger.debug "Using image #{image_id} instead of building new image"
             Docker::Image.get(image_id)
           else
             @logger.debug "No image exists for #{dockerfile}"
             @logger.debug "Building a new image with #{dockerfile} " \
                           "using #{build_dir} as build context directory"

             Docker::Image.build_from_dir(build_dir, t: image_name) do |chunk|
               if (log = JSON.parse(chunk)) && log.has_key?('stream')
                 @logger.info log['stream']
               end
             end.tap do |image|
               @global_state.modify do |global|
                 global['images'][dockerfile_hash] = image.id
               end
             end
           end
         end

         # If another image is already tagged with the tag, remove it first
         if Docker::Image.exist?(image_name)
           existing_image = Docker::Image.get(image_name)
           if existing_image.id != image.id
             begin
               existing_image.remove
             rescue Docker::Error::ConflictError
               @logger.warn "Unable to remove tag from previous '#{image_name}' image (#{image.id})"
             end
           end
         end

         unless Docker::Image.exist?(image_name)
           @logger.debug "Tagging #{image.id} with '#{image_name}'..."
           image.tag(repo: 'navo', tag: name)
           @logger.debug "Image #{image.id} tagged with '#{image_name}'"
         end

         image
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

            # Until Docker supports colons in paths for volume specs [1], we
            # assume that a spec containing no colons indicates the user wants
            # to create a data volume.
            # [1] https://github.com/docker/docker/issues/8604
            data_volumes, bind_mounts = container_volumes.partition { |spec| spec =~ %r{^/[^:]*$} }
            data_volumes_hash = Hash[data_volumes.map { |path| [path, {}] }]

            container = Docker::Container.create(
              'name' => container_name, # Special key handled by docker-api gem
              'Image' => image.id,
              'Hostname' => hostname,
              'OpenStdin' => true,
              'StdinOnce' => true,
              'Volumes' => data_volumes_hash,
              'HostConfig' => {
                'Privileged' => @config['docker']['privileged'],
                'Binds' => bind_mounts + %W[
                  #{Berksfile.vendor_directory}:#{File.join(chef_run_dir, 'cookbooks')}
                  #{File.join(repo_root, 'data_bags')}:#{File.join(chef_run_dir, 'data_bags')}
                  #{File.join(repo_root, 'environments')}:#{File.join(chef_run_dir, 'environments')}
                  #{File.join(repo_root, 'roles')}:#{File.join(chef_run_dir, 'roles')}
                ],
              },
            )

            state['container'] = container.id
          end

          unless started?(container.id)
            @logger.info "Starting container #{container.id}"
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
      @state ||= StateFile.new(file: File.join(storage_directory, 'state.yaml'),
                               logger: @logger).tap(&:load)
    end

    def hostname
      # Hostnames cannot contain underscores. While a node name isn't a
      @config['suites'][name].fetch('hostname', name).gsub('_', '-')
    end

    def container_name
      # Base container name off of suite name but append a unique
      # identifier based on the repo path (so multiple repos on the same system
      # with the same suite name can stand up their own test suites without name
      # conflicts)
      "navo-#{name}-#{Digest::MD5.new.hexdigest(repo_root)[0..4]}"
    end

    def container_volumes
      (Array(@config['docker']['volumes']) +
       Array(@config['suites'][name]['volumes'])).flatten
    end

    def close_log
      @logger.close
    end

    def log_file
      @log_file ||= File.join(storage_directory, 'log.log')
    end
  end
end
