require 'eventmachine'

module FreeswitchESL
  module Outbound
    # One TCP connection from FreeSWITCH (`socket host:port async full`).
    #
    # Flow (see mod_event_socket.c, socket_application_fn):
    #   1. FreeSWITCH connects and waits for the `connect` command.
    #   2. We send "connect"; FreeSWITCH answers with a command/reply frame
    #      that also carries the whole channel data (Unique-ID, caller, ...).
    #   3. The channel is parked; we drive it with sendmsg/execute and receive
    #      events as text/event-plain while the socket stays open.
    class Connection < EM::Connection
      attr_accessor :server, :session
      attr_reader :logger

      def post_init
        @framer = Framer.new
        @api_callbacks = []
        @job_callbacks = {}
        @bgapi_pending = []
        @logger = server&.logger
        @logger&.debug "[FS-ESL OUTBOUND] New connection from #{peer_address}"
        server&.track(self)
        # Async outbound mode: FreeSWITCH will not send channel data until we ask.
        send_command('connect')
      end

      def receive_data(data)
        @framer << data
        @framer.each_frame do |frame|
          handle_frame(frame)
        rescue StandardError => e
          @logger&.error "[FS-ESL OUTBOUND] Frame error: #{e.class}: #{e.message}"
          @logger&.error e.backtrace.first(5).join("\n")
        end
      end

      def handle_frame(frame)
        headers = frame[:headers]
        body = frame[:body].to_s

        case frame[:content_type]
        when 'command/reply'
          reply = headers['Reply-Text'].to_s
          if session.nil? && headers['Unique-ID']
            # The very first reply also contains the whole channel data.
            start_session(headers)
          elsif reply.include?('Job-UUID:')
            job_uuid = reply[/Job-UUID:\s*(\S+)/, 1]
            callback = @bgapi_pending.shift
            @job_callbacks[job_uuid] = callback if job_uuid && callback
          else
            @logger&.debug "[FS-ESL OUTBOUND] reply: #{reply}"
          end
        when 'api/response'
          callback = @api_callbacks.shift
          callback&.call(Response.new(headers, body))
        when 'text/event-plain'
          event, event_body = Parser.parse_event(body)
          dispatch_event(event, event_body)
        when 'text/event-json'
          event, event_body = Parser.parse_event(body)
          dispatch_event(event, event_body)
        when 'text/disconnect-notice'
          @logger&.debug '[FS-ESL OUTBOUND] Disconnect notice'
          close_connection
        else
          if session.nil? && headers['Unique-ID']
            start_session(headers)
          elsif body.include?('Event-Name:')
            event, event_body = Parser.parse_event(body)
            dispatch_event(event, event_body)
          end
        end
      end

      def start_session(headers)
        @session = Session.new(self, headers)
        @logger&.info "[FS-ESL OUTBOUND] Session #{@session.uuid} from #{@session.caller_id_number} to #{@session.destination_number}"
        # Outbound sockets receive no events until they subscribe (mod_event_socket.c
        # only delivers when LFLAG_EVENTS is set by the `event` command).
        send_command("event plain #{Session::DEFAULT_EVENTS.join(' ')}")
        server&.handler&.call(@session)
      end

      def dispatch_event(event, raw_body)
        name = event['Event-Name'].to_s

        if name == 'BACKGROUND_JOB'
          callback = @job_callbacks.delete(event['Job-UUID'])
          callback&.call(Response.new(event, raw_body))
          return
        end

        return unless session
        return unless belongs_to_session?(event)

        session.handle_event(event, raw_body)
      end

      # An outbound socket gets events for every channel in the system, so only
      # forward the ones that belong to our dialog.
      def belongs_to_session?(event)
        uuid = session&.uuid
        return false unless uuid
        return true if event['Unique-ID'] == uuid

        %w[Bridge-A-Unique-ID Bridge-B-Unique-ID Other-Leg-Unique-ID Originating-Leg-Unique-ID]
          .any? { |key| event[key] == uuid }
      end

      # -------------------------------------------------------------- commands

      def send_command(command)
        data = command.end_with?("\n\n") ? command : "#{command}\n\n"
        @logger&.debug "[FS-ESL OUTBOUND] -> #{command.strip}"
        send_data(data)
      end

      def execute(app, args = nil, job_uuid: nil)
        lines = ['sendmsg']
        lines << "call-command: execute"
        lines << "execute-app-name: #{app}"
        lines << "execute-app-arg: #{args}" if args && !args.to_s.empty?
        lines << "event-lock: true"
        lines << "Job-UUID: #{job_uuid}" if job_uuid
        send_command(lines.join("\n"))
      end

      def api(command, &block)
        @api_callbacks << block if block
        send_command("api #{command}")
      end

      def bgapi(command, &block)
        @bgapi_pending << block if block
        send_command("bgapi #{command}")
        nil
      end

      def unbind
        @logger&.debug '[FS-ESL OUTBOUND] Connection closed'
        server&.untrack(self)
        session&.close
      end

      def peer_address
        get_peername ? Socket.unpack_sockaddr_in(get_peername).reverse.join(':') : 'unknown'
      rescue StandardError
        'unknown'
      end
    end
  end
end
