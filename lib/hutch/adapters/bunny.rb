require 'bunny'
require 'forwardable'

module Hutch
  module Adapters
    class BunnyAdapter
      extend Forwardable

      DEFAULT_VHOST = Bunny::Session::DEFAULT_VHOST

      def_delegators :@connection, :start, :disconnect, :close, :create_channel, :open?

      def initialize(opts={})
        @connection = Bunny.new(opts)
      end

      def prefetch_channel(ch, prefetch)
        ch.prefetch(prefetch) if prefetch
      end

      def current_timestamp
        Time.now.to_i
      end
    end
  end
end
