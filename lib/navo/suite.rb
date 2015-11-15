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
      system("docker cp #{from} #{container.id}:#{to}")
    end

    # Write contents to a file on the container.
    def write(file:, content:)
      container.exec(%w[bash -c] + ["cat > #{file}"], stdin: StringIO.new(content))
    end

    # Execte a command on the container.
    def exec(args)
      container.exec(args) do |_stream, chunk|
        STDOUT.print chunk
      end
    end

    # Execute a command on the container, raising an error if it exists
    # unsuccessfully.
    def exec!(args)
      out, err, status = exec(args)
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
      container
    end

    def converge
      create

      sandbox.update_chef_config

      _, _, status = exec(%W[
        /opt/chef/embedded/bin/chef-solo
        --config=#{File.join(chef_config_dir, 'solo.rb')}
        --json-attributes=#{File.join(chef_config_dir, 'first-boot.json')}
        --force-formatter
      ])

      state['converged'] = status == 0
      state.save
      state['converged']
    end

    def verify
      create

      sandbox.update_test_config

      _, _, status = exec(['/usr/bin/env'] + busser_env + %W[#{busser_bin} test])
      status == 0
    end

    def test
      return false unless converge
      verify
    end

    def destroy
      if @config['docker']['stop-command']
        exec(@config['docker']['stop-command'])
        container.wait(@config['docker'].fetch('stop-timeout', 10))
      else
        container.stop
      end

      container.remove(force: true)

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
         image_id = state['images'][dockerfile_hash]

         if image_id && Docker::Image.exist?(image_id)
           Docker::Image.get(image_id)
         else
           Docker::Image.build_from_dir(build_dir) do |chunk|
             if (log = JSON.parse(chunk)) && log.has_key?('stream')
               STDOUT.print log['stream']
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
          if state['container']
            begin
              container = Docker::Container.get(state['container'])
            rescue Docker::Error::NotFoundError
              # Continue creating the container since it doesn't exist
            end
          end

          if !container
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

          container.start
        end
    end

    def sandbox
      @sandbox ||= Sandbox.new(suite: self)
    end

    def storage_directory
      File.join(repo_root, '.navo', 'suites', name)
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
      @state ||= SuiteState.new(suite: self).tap(&:load)
    end
  end
end
