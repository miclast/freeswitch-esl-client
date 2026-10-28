module FreeswitchESL
  module Outbound
    # A live outbound call handed to us by FreeSWITCH.
    #
    # All the app methods are fire-and-forget: FreeSWITCH queues the commands
    # on this channel and executes them in order, so
    #
    #   session.answer
    #   session.play('ivr/ivr-welcome.wav')
    #   session.hangup
    #
    # behaves as expected. Register event handlers with #on if you need to
    # react to the call (DTMF, bridge, hangup...).
    class Session
      # Events an outbound socket has to subscribe to explicitly; without the
      # `event` command FreeSWITCH delivers nothing.
      DEFAULT_EVENTS = %w[
        CHANNEL_CREATE CHANNEL_ANSWER CHANNEL_BRIDGE CHANNEL_UNBRIDGE
        CHANNEL_HANGUP CHANNEL_HANGUP_COMPLETE CHANNEL_DESTROY CHANNEL_STATE
        CHANNEL_EXECUTE CHANNEL_EXECUTE_COMPLETE DTMF RECORD_STOP PLAYBACK_STOP
        BACKGROUND_JOB CUSTOM
      ].freeze

      attr_reader :uuid, :caller_id_number, :caller_id_name, :destination_number,
                  :headers, :connection, :state, :hangup_cause

      def initialize(conn, headers)
        @connection = conn
        @headers = headers || {}
        @uuid = @headers['Unique-ID']
        @caller_id_number = @headers['Caller-Caller-ID-Number'] || @headers['variable_caller_id_number']
        @caller_id_name = @headers['Caller-Caller-ID-Name'] || @headers['variable_caller_id_name']
        @destination_number = @headers['Caller-Destination-Number'] ||
                              @headers['variable_destination_number'] ||
                              @headers['Caller-ANI']
        @state = @headers['Channel-State']
        @context = @headers['Caller-Context']
        @answered = false
        @ended = false
        @handlers = Hash.new { |h, k| h[k] = [] }
      end

      # ---------------------------------------------------------------- events

      # session.on('CHANNEL_ANSWER') { |event| ... }
      # session.on('DTMF') { |event| ... }
      # session.on('*') { |event| ... }
      def on(event_name, &block)
        @handlers[event_name.to_s.upcase] << block
        self
      end

      def handle_event(event, _raw_body = nil)
        name = event['Event-Name'].to_s.upcase
        @state = event['Channel-State'] if event['Channel-State']

        case name
        when 'CHANNEL_ANSWER'
          @answered = true
        when 'CHANNEL_HANGUP_COMPLETE'
          @hangup_cause = event['Hangup-Cause']
          @ended = true
        when 'CHANNEL_DESTROY'
          @ended = true
        end

        Array(@handlers[name]).each { |handler| safe_call(handler, event) }
        Array(@handlers['*']).each { |handler| safe_call(handler, event) }
        self
      end

      def safe_call(handler, event)
        handler.call(event)
      rescue StandardError => e
        connection&.logger&.error "[FS-ESL OUTBOUND] handler error: #{e.class}: #{e.message}"
      end

      def answered?
        @answered
      end

      def ended?
        @ended
      end

      # --------------------------------------------------------------- commands

      def answer
        execute('answer')
        @answered = true
        self
      end

      def pre_answer
        execute('pre_answer')
        self
      end

      def ring_ready
        execute('ring_ready')
        self
      end

      def hangup(cause = 'NORMAL_CLEARING')
        execute('hangup', cause)
        self
      end

      def play(file)
        execute('playback', file)
        self
      end

      def play_and_get_digits(min = 1, max = 10, tries = 3, timeout = 3000, terminators = '#',
                              file = 'silence_stream://10', invalid_file = nil, var_name = 'digits',
                              digit_timeout = 3000)
        args = [
          min, max, tries, timeout, terminators, file,
          invalid_file || 'silence_stream://150', var_name, digit_timeout
        ].join(' ')
        execute('play_and_get_digits', args)
        self
      end

      def read(min = 1, max = 10, file = 'silence_stream://10', timeout = 3000,
               terminators = '#', var_name = 'digits')
        execute('read', [min, max, file, var_name, timeout, terminators].join(' '))
        self
      end

      def record(file, limit = 3600, silence_thresh = 200, silence_hits = 5)
        execute('record', [file, limit, silence_thresh, silence_hits].join(' '))
        self
      end
      alias record_file record

      def speak(text, engine: nil, voice: nil)
        if engine && voice
          execute('speak', "#{engine}|#{voice}|#{text}")
        else
          execute('speak', text)
        end
        self
      end

      def bridge(dialstring)
        execute('bridge', dialstring)
        self
      end

      def transfer(extension, dialplan: 'XML', context: 'default')
        execute('transfer', "#{extension} #{dialplan} #{context}")
        self
      end

      def park
        execute('park')
        self
      end

      def set(name, value)
        execute('set', "#{name}=#{value}")
        self
      end

      def export(name, value)
        execute('export', "#{name}=#{value}")
        self
      end

      def unset(name)
        execute('unset', name)
        self
      end

      def sleep(ms)
        execute('sleep', ms.to_s)
        self
      end

      def flush_dtmf
        execute('flush_dtmf')
        self
      end

      def send_dtmf(dtmf)
        execute('send_dtmf', dtmf)
        self
      end

      def execute(app, args = nil, &block)
        connection.execute(app, args, &block)
        self
      end

      def api(command, &block)
        connection.api(command, &block)
      end

      def bgapi(command, &block)
        connection.bgapi(command, &block)
      end

      def send_command(command)
        connection.send_command(command)
      end

      # ---------------------------------------------------------------- helpers

      def variable(name)
        @headers["variable_#{name}"] || @headers[name]
      end
      alias [] variable

      def close; end
    end
  end
end
