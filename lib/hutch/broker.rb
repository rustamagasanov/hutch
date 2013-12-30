require 'bunny'
require 'carrot-top'
require 'securerandom'
require 'hutch/logging'
require 'hutch/exceptions'

module Hutch
  class Broker
    include Logging

    attr_accessor :connection, :channel, :exchange, :api_client

    def initialize(config = nil)
      @config = config || Hutch::Config
    end

    def connect(options = {})
      set_up_amqp_connection
      set_up_api_connection if options.fetch(:enable_http_api_use, true)

      if block_given?
        yield
        disconnect
      end
    end

    def disconnect
      @channel.close    if @channel
      @connection.close if @connection
      @channel, @connection, @exchange, @api_client = nil, nil, nil, nil
    end

    # Connect to RabbitMQ via AMQP. This sets up the main connection and
    # channel we use for talking to RabbitMQ. It also ensures the existance of
    # the exchange we'll be using.
    def set_up_amqp_connection
      conn     = open_connection
      @channel = open_channel(conn)

      exchange_name = @config[:mq_exchange]
      logger.info "using topic exchange '#{exchange_name}'"
      @exchange = @channel.topic(exchange_name, durable: true)
    rescue Bunny::TCPConnectionFailed => ex
      logger.error "amqp connection error: #{ex.message.downcase}"
      uri = "#{protocol}#{host}:#{port}"
      raise ConnectionError.new("couldn't connect to rabbitmq at #{uri}")
    rescue Bunny::PreconditionFailed => ex
      logger.error ex.message
      raise WorkerSetupError.new('could not create exchange due to a type ' +
                                 'conflict with an existing exchange, ' +
                                 'remove the existing exchange and try again')
    end

    def open_connection
      host     = @config[:mq_host]
      port     = @config[:mq_port]
      vhost    = @config[:mq_vhost]
      username = @config[:mq_username]
      password = @config[:mq_password]
      tls      = @config[:mq_tls]
      tls_key  = @config[:mq_tls_cert]
      tls_cert = @config[:mq_tls_key]
      protocol = tls ? "amqps://" : "amqp://"
      uri      = "#{username}:#{password}@#{host}:#{port}/#{vhost.sub(/^\//, '')}"
      logger.info "connecting to rabbitmq (#{protocol}#{uri})"

      @connection = Bunny.new(host: host, port: port, vhost: vhost,
                              tls: tls, tls_key: tls_key, tls_cert: tls_cert,
                              username: username, password: password,
                              heartbeat: 30, automatically_recover: true,
                              network_recovery_interval: 1)
      @connection.start
      @connection
    end

    def open_channel(connection)
      logger.info 'opening rabbitmq channel'
      connection.create_channel
    end

    # Set up the connection to the RabbitMQ management API. Unfortunately, this
    # is necessary to do a few things that are impossible over AMQP. E.g.
    # listing queues and bindings.
    def set_up_api_connection
      logger.info "connecting to rabbitmq management api (#{api_config.management_uri})"

      with_authentication_error_handler do
        with_connection_error_handler do
          @api_client = CarrotTop.new(host: api_config.host, port: api_config.port,
                                      user: api_config.username, password: api_config.password,
                                      ssl: api_config.ssl)
          @api_client.exchanges
        end
      end
    end

    # Create / get a durable queue.
    def queue(name)
      @channel.queue(name, durable: true)
    end

    # Return a mapping of queue names to the routing keys they're bound to.
    def bindings
      results = Hash.new { |hash, key| hash[key] = [] }
      @api_client.bindings.each do |binding|
        next if binding['destination'] == binding['routing_key']
        next unless binding['source'] == @config[:mq_exchange]
        next unless binding['vhost'] == @config[:mq_vhost]
        results[binding['destination']] << binding['routing_key']
      end
      results
    end

    # Bind a queue to the broker's exchange on the routing keys provided. Any
    # existing bindings on the queue that aren't present in the array of
    # routing keys will be unbound.
    def bind_queue(queue, routing_keys)
      # Find the existing bindings, and unbind any redundant bindings
      queue_bindings = bindings.select { |dest, keys| dest == queue.name }
      queue_bindings.each do |dest, keys|
        keys.reject { |key| routing_keys.include?(key) }.each do |key|
          logger.debug "removing redundant binding #{queue.name} <--> #{key}"
          queue.unbind(@exchange, routing_key: key)
        end
      end

      # Ensure all the desired bindings are present
      routing_keys.each do |routing_key|
        logger.debug "creating binding #{queue.name} <--> #{routing_key}"
        queue.bind(@exchange, routing_key: routing_key)
      end
    end

    # Each subscriber is run in a thread. This calls Thread#join on each of the
    # subscriber threads.
    def wait_on_threads(timeout)
      # Thread#join returns nil when the timeout is hit. If any return nil,
      # the threads didn't all join so we return false.
      per_thread_timeout = timeout.to_f / work_pool_threads.length
      work_pool_threads.none? { |thread| thread.join(per_thread_timeout).nil? }
    end

    def stop
      @channel.work_pool.kill
    end

    def ack(delivery_tag)
      @channel.ack(delivery_tag, false)
    end

    def publish(routing_key, message, properties = {})
      payload = JSON.dump(message)

      unless @connection
        msg = "Unable to publish - no connection to broker. " +
              "Message: #{message.inspect}, Routing key: #{routing_key}."
        logger.error(msg)
        raise PublishError, msg
      end

      unless @connection.open?
        msg = "Unable to publish - connection is closed. " +
              "Message: #{message.inspect}, Routing key: #{routing_key}."
        logger.error(msg)
        raise PublishError, msg
      end

      non_overridable_properties = {
        routing_key: routing_key,
        timestamp: Time.now.to_i,
        content_type: 'application/json'
      }
      properties[:message_id] ||= generate_id

      logger.info("publishing message '#{message.inspect}' to #{routing_key}")
      @exchange.publish(payload, {persistent: true}.
        merge(properties).
        merge(global_properties).
        merge(non_overridable_properties))
    end

    private

    def api_config
      @api_config ||= OpenStruct.new.tap do |config|
        config.host = @config[:mq_api_host]
        config.port = @config[:mq_api_port]
        config.username = @config[:mq_username]
        config.password = @config[:mq_password]
        config.ssl = @config[:mq_api_ssl]
        config.protocol = config.ssl ? "https://" : "http://"
        config.management_uri = "#{config.protocol}#{config.username}:#{config.password}@#{config.host}:#{config.port}/"
      end
    end

    def with_authentication_error_handler
      yield
    rescue Net::HTTPServerException => ex
      logger.error "api connection error: #{ex.message.downcase}"
      if ex.response.code == '401'
        raise AuthenticationError.new('invalid api credentials')
      else
        raise
      end
    end

    def with_connection_error_handler
      yield
    rescue Errno::ECONNREFUSED => ex
      logger.error "api connection error: #{ex.message.downcase}"
      raise ConnectionError.new("couldn't connect to api at #{api_config.management_uri}")
    end

    def work_pool_threads
      @channel.work_pool.threads || []
    end

    def generate_id
      SecureRandom.uuid
    end

    def global_properties
      Hutch.global_properties.respond_to?(:call) ? Hutch.global_properties.call : Hutch.global_properties
    end
  end
end

