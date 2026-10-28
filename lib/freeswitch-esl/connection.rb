require 'eventmachine'

module FreeswitchESL
  class Connection < EM::Connection
    attr_accessor :password, :client

    def post_init
      @framer = Framer.new
      client&.logger&.debug '[FS-ESL] Connection established'
    end

    def receive_data(data)
      @framer << data
      @framer.each_frame do |frame|
        begin
          client&.handle_frame(self, frame)
        rescue StandardError => e
          client&.logger&.error "[FS-ESL] Error handling frame: #{e.class}: #{e.message}"
          client&.logger&.error e.backtrace.first(5).join("\n")
        end
      end
    end

    def send_command(cmd)
      return unless client

      client.logger&.debug "[FS-ESL] -> #{cmd.strip}"
      send_data(cmd.end_with?("\n\n") ? cmd : "#{cmd}\n\n")
    end

    def unbind
      client&.connection_closed(self)
    end
  end
end
