class Chef
  module Formatters
    class NavoFormatter < Formatters::Base
      cli_name(:navo)

      def initialize(out, err)
        super

        @up_to_date_resources = 0
        @updated_resources = 0
        @skipped_resources = 0
        @resource_stack = []
        @resource_action_times = Hash.new { |hash, key| hash[key] = [] }

        @deprecations = {}
      end

      def total_resources
        @up_to_date_resources + @updated_resources + @skipped_resources
      end

      def print_deprecations
        return if @deprecations.empty?
        puts_line 'Deprecated features used!'

        @deprecations.each do |message, locations|
          if locations.size == 1
            puts_line "  #{message} at one location:"
          else
            puts_line "  #{message} at #{locations.size} locations:"
          end
          locations.each do |location|
            prefix = '    - '
            Array(location).each do |line|
              puts_line "#{prefix}#{line}"
              prefix = '      '
            end
          end
        end
        puts_line ''
      end

      def run_start(version)
        @start_time = Time.now
        puts_line "Starting Chef client #{version}...", :cyan
      end

      def ohai_completed(node)
        puts_line ''
        puts_line 'Ohai run completed', :cyan
      end

      def library_load_start(file_count)
        @load_start_time = Time.now
        puts_line ''
        puts_line 'Loading cookbook libraries...', :cyan
      end

      def library_load_complete
        elapsed = Time.now - @load_start_time
        puts_line "Loaded cookbook libraries (#{elapsed}s)", :cyan
      end

      def attribute_load_start(file_count)
        @load_start_time = Time.now
        puts_line ''
        puts_line 'Loading cookbook attributes...', :cyan
      end

      def attribute_load_complete
        elapsed = Time.now - @load_start_time
        puts_line "Loaded cookbook attributes (#{elapsed}s)", :cyan
      end

      def lwrp_load_start(file_count)
        @load_start_time = Time.now
        puts_line ''
        puts_line 'Loading custom resources...', :cyan
      end

      def lwrp_load_complete
        elapsed = Time.now - @load_start_time
        puts_line "Loaded custom resources (#{elapsed}s)", :cyan
      end

      def definition_load_start(file_count)
        @load_start_time = Time.now
        puts_line ''
        puts_line 'Loading definitions...', :cyan
      end

      def definition_load_complete
        elapsed = Time.now - @load_start_time
        puts_line "Loaded definitions (#{elapsed}s)", :cyan
      end

      def recipe_load_start(recipes)
        @load_start_time = Time.now
        puts_line ''
        puts_line "Loading recipes...", :cyan
      end

      def recipe_load_complete
        elapsed = Time.now - @load_start_time
        puts_line "Recipes loaded (#{elapsed}s)", :cyan
      end

      def file_loaded(path)
        puts_line "Loaded #{path}"
      end

      def converge_start(run_context)
        puts_line ''
        puts_line "Converging #{run_context.resource_collection.all_resources.size} resources..."
      end

      def converge_complete
        unindent while @resource_stack.pop
        puts_line ''
        puts_line 'Converge completed', :green
      end

      def converge_failed(e)
        unindent while @resource_stack.pop
        puts_line ''
        puts_line "Converge failed: #{e}", :red
      end

      def resource_action_start(resource, action, notification_type = nil, notifier = nil)
        # Track the current recipe so we update it only when it changes
        # (i.e. when descending into another recipe via include_recipe)
        if resource.cookbook_name && resource.recipe_name
          current_recipe = "#{resource.cookbook_name}::#{resource.recipe_name}"

          unless current_recipe == @current_recipe
            @current_recipe = current_recipe
            puts_line current_recipe, :magenta
          end
        end

        # Record the resource and the time we started so we can figure out how
        # long it took to complete
        @resource_stack << [resource, Time.now]
        indent

        puts_line "#{resource} action #{action}"
      end

      def resource_failed_retriable(resource, action, retry_count, exception)
        puts_line "#{resource} action #{action} FAILED; retrying...", :yellow
      end

      # Called when a resource fails and will not be retried.
      def resource_failed(resource, action, exception)
        _, start_time = @resource_stack.pop
        elapsed = Time.now - start_time
        @resource_action_times[[resource.to_s, action.to_s]] << elapsed
        puts_line "#{resource} action #{action} (#{elapsed}s) FAILED: #{exception}", :red
        unindent
      end

      def resource_skipped(resource, action, conditional)
        @skipped_resources += 1
        _, start_time = @resource_stack.pop
        elapsed = Time.now - start_time
        @resource_action_times[[resource.to_s, action.to_s]] << elapsed
        puts_line "#{resource} action #{action} (#{elapsed}s) SKIPPED due to: #{conditional.short_description}"
        unindent
      end

      def resource_up_to_date(resource, action)
        @up_to_date_resources += 1
        _, start_time = @resource_stack.pop
        elapsed = Time.now - start_time
        @resource_action_times[[resource.to_s, action.to_s]] << elapsed
        puts_line "#{resource} action #{action} up-to-date (#{elapsed}s)"
        unindent
      end

      def resource_update_applied(resource, action, update)
        indent

        Array(update).compact.each do |line|
          if line.is_a?(String)
            puts_line "- #{line}", :green
          elsif line.is_a?(Array)
            # Expanded output delta
            line.each do |detail|
              if detail =~ /^\+(?!\+\+ )/
                color = :green
              elsif detail =~ /^-(?!-- )/
                color = :red
              else
                color = :cyan
              end
              puts_line detail, color
            end
          end
        end

        unindent
      end

      def resource_updated(resource, action)
        @updated_resources += 1
        _, start_time = @resource_stack.pop
        elapsed = Time.now - start_time
        @resource_action_times[[resource.to_s, action.to_s]] << elapsed
        puts_line "#{resource} action #{action} updated (#{elapsed}s)"
        unindent
      end

      def handlers_start(handler_count)
        @handler_count = handler_count
        puts_line ''
        if @handler_count > 0
          puts_line "Running #{handler_count} handlers:", :cyan
        else
          puts_line 'No registered handlers to run', :cyan
        end
      end

      def handler_executed(handler)
        puts_line "- #{handler.class.name}"
      end

      def handlers_completed
        puts_line 'Running handlers complete' unless @handler_count == 0
      end

       def deprecation(message, location=caller(2..2)[0])
        if Chef::Config[:treat_deprecation_warnings_as_errors]
          super
        end

        # Save deprecations to the screen until the end
        @deprecations[message] ||= Set.new
        @deprecations[message] << location
      end

      def run_completed(node)
        @end_time = Time.now

        print_deprecations

        puts_line ''
        print_resource_summary
        puts_line "Chef client finished in #{@end_time - @start_time} seconds", :cyan
      end

      private

      def print_resource_summary
        puts_line "#{@updated_resources}/#{total_resources} resources updated"

        slowest_resources = @resource_action_times.sort_by do |key, values|
          -values.inject(:+)
        end

        puts_line 'Slowest resource actions:'
        slowest_resources[0...10].each do |key, values|
          elapsed = '%-.3fs' % values.inject(:+)
          puts_line "#{elapsed.ljust(8)} #{key.first} (#{key[1]})"
        end

        puts_line ''
      end

      def indent
        indent_by 2
      end

      def unindent
        indent_by -2
      end
    end
  end
end
