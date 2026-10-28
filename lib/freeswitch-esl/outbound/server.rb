require 'eventmachine'
require 'logger'

module FreeswitchESL
  module Outbound
    # Outbound ESL server.
    #
    #   EM.run do
    #     server = FreeswitchESL.outbound_server(port: 8084) do |session|
    #       session.answer
    #       session.play('ivr/ivr-welcome_to_freeswitch.wav')
    #       session.hangup
    #     end
    #     server.start
    #   end
    class Server
      attr_reader :host, :port, :handler, :logger
      attr_accessor :signature

      def initialize(host: '0.0.0.0', port: 8084, logger: nil, &block)
        @host = host
        @port = port
        @handler = block
        @logger = logger || Logger.new($stdout)
        @running = false
        @connections = []
      end

      def start
        return self if @running

        @logger.info "[FS-ESL OUTBOUND] Starting server on #{@host}:#{@port}"
        @signature = EM.start_server(@host, @port, Connection) do |conn|
          conn.server = self
        end
        @running = true
        self
      end

      def stop
        EM.stop_server(@signature) if @signature
        @signature = nil
        @running = false
        self
      end

      def running?
        @running
      end

      # Called by Connection#post_init / #unbind
      def track(conn)
        @connections << conn
      end

      def untrack(conn)
        @connections.delete(conn)
      end

      def connections
        @connections
      end
    end
  end
end
