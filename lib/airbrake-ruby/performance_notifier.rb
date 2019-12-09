module Airbrake
  # QueryNotifier aggregates information about SQL queries and periodically sends
  # collected data to Airbrake.
  #
  # @api public
  # @since v3.2.0
  class PerformanceNotifier
    include Inspectable
    include Loggable

    def initialize
      @config = Airbrake::Config.instance
      @flush_period = Airbrake::Config.instance.performance_stats_flush_period
      @sender = AsyncSender.new(:put)
      @payload = {}
      @schedule_flush = nil
      @mutex = Mutex.new
      @filter_chain = FilterChain.new
      @waiting = false
    end

    # @param [Hash] resource
    # @see Airbrake.notify_query
    # @see Airbrake.notify_request
    def notify(resource)
      promise = @config.check_configuration
      return promise if promise.rejected?

      promise = @config.check_performance_options(resource)
      return promise if promise.rejected?

      @filter_chain.refine(resource)
      return if resource.ignored?

      @mutex.synchronize do
        update_payload(resource)
        @flush_period > 0 ? schedule_flush : send(@payload, promise)
      end

      promise.resolve(:success)
    end

    # @see Airbrake.add_performance_filter
    def add_filter(filter = nil, &block)
      @filter_chain.add_filter(block_given? ? block : filter)
    end

    # @see Airbrake.delete_performance_filter
    def delete_filter(filter_class)
      @filter_chain.delete_filter(filter_class)
    end

    def close
      @mutex.synchronize do
        @schedule_flush.kill if @schedule_flush
        @sender.close
        logger.debug("#{LOG_LABEL} performance notifier closed")
      end
    end

    private

    def update_payload(resource)
      if (total_stat = @payload[resource])
        @payload.key(total_stat).merge(resource)
      else
        @payload[resource] = { total: Airbrake::Stat.new }
      end

      @payload[resource][:total].increment(resource.start_time, resource.end_time)

      resource.groups.each do |name, ms|
        @payload[resource][name] ||= Airbrake::Stat.new
        @payload[resource][name].increment_ms(ms)
      end
    end

    def schedule_flush
      return if @payload.empty?

      if @schedule_flush && @schedule_flush.status == 'sleep' && @waiting
        begin
          @schedule_flush.run
        rescue ThreadError => exception
          logger.error("#{LOG_LABEL}: error occurred while flushing: #{exception}")
        end
      end

      @schedule_flush ||= spawn_timer
    end

    def spawn_timer
      Thread.new do
        loop do
          if @payload.none?
            @waiting = true
            Thread.stop
            @waiting = false
          end

          sleep(@flush_period)

          payload = nil
          @mutex.synchronize do
            payload = @payload
            @payload = {}
          end

          send(payload, Airbrake::Promise.new)
        end
      end
    end

    def send(payload, promise)
      signature = "#{self.class.name}##{__method__}"
      raise "#{signature}: payload (#{payload}) cannot be empty. Race?" if payload.none?

      logger.debug { "#{LOG_LABEL} #{signature}: #{payload}" }

      with_grouped_payload(payload) do |resource_hash, destination|
        url = URI.join(
          @config.host,
          "api/v5/projects/#{@config.project_id}/#{destination}"
        )
        @sender.send(resource_hash, promise, url)
      end

      promise
    end

    def with_grouped_payload(raw_payload)
      grouped_payload = raw_payload.group_by do |resource, _stats|
        [resource.cargo, resource.destination]
      end

      grouped_payload.each do |(cargo, destination), resources|
        payload = {}
        payload[cargo] = serialize_resources(resources)
        payload['environment'] = @config.environment if @config.environment

        yield(payload, destination)
      end
    end

    def serialize_resources(resources)
      resources.map do |resource, stats|
        resource_hash = resource.to_h.merge!(stats[:total].to_h)

        if resource.groups.any?
          group_stats = stats.reject { |name, _stat| name == :total }
          resource_hash['groups'] = group_stats.merge(group_stats) do |_name, stat|
            stat.to_h
          end
        end

        resource_hash
      end
    end
  end
end
