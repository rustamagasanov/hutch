require 'march_hare'
require 'forwardable'

module Hutch
  module Adapters
    class MarchHareAdapter
      extend Forwardable

      DEFAULT_VHOST = "/"

      def_delegators :@connection, :start, :disconnect, :close, :open?

      def initialize(opts = {})
        @connection = MarchHare.connect(opts)
      end

      def prefetch_channel(ch, prefetch)
        ch.prefetch = prefetch if prefetch
      end

      def create_channel(n = nil, consumer_pool_size = 1)
        @connection.create_channel(n)
      end

      def current_timestamp
        Time.now
      end
    end
  end
end
