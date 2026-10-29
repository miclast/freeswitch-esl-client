require 'eventmachine'
require 'securerandom'
require 'logger'
require_relative 'connection'
require_relative 'parser'
require_relative 'response'
require_relative 'errors'

module FreeswitchESL
  # Inbound ESL client: connects to mod_event_socket (default :8021),
  # authenticates, subscribes to events and exposes api/bgapi.
  #
  #   EM.run do
  #     client = FreeswitchESL::Client.new(host: '127.0.0.1', password: 'ClueCon')
  #     client.on('CHANNEL_ANSWER') { |event| puts event['Unique-ID'] }
  #     client.connect!
  #     client.api('status') { |res| puts res.body }
  #   end
  #
  # The client can also own its reactor thread (no surrounding EM.run needed);
  # in that case #connect! spawns one and #close! shuts it down.
  class Client
    DEFAULT_EVENTS = %w[
      CHANNEL_CREATE CHANNEL_ANSWER CHANNEL_BRIDGE CHANNEL_HANGUP_COMPLETE
      CHANNEL_DESTROY CHANNEL_CALLSTATE CHANNEL_EXECUTE BACKGROUND_JOB
    ].freeze

    attr_accessor :connected, :reconnect_interval, :closing
    attr_reader :host, :port, :password, :logger

    def initialize(host: '127.0.0.1', port: 8021, password: 'ClueCon', logger: nil,
                   reconnect_interval: 2, events: DEFAULT_EVENTS, auto_reconnect: true)
      @host = host
      @port = port
      @password = password
      @logger = logger || Logger.new($stdout)
      @reconnect_interval = reconnect_interval
      @events = events
      @auto_reconnect = auto_reconnect

      @connected = false
      @authenticated = false
      @closing = false
      @connecting = false
      @owns_reactor = false

      @conn = nil
      @queue = []
      @api_callbacks = []
      @job_callbacks = {}
      @bgapi_callbacks = []
      @event_handlers = {}
    end

    # ---------------------------------------------------------------- lifecycle

    def connect!
      connect
    end

    def connect
      return if @connecting || @connected

      @connecting = true
      @closing = false
      @logger.info "[FS-ESL] Connecting to #{@host}:#{@port}..."

      if EM.reactor_thread?
        open_socket
      else
        @owns_reactor = true
        Thread.new { EM.run { open_socket } }
      end
      self
    end

    def open_socket
      EM.connect(@host, @port, Connection) do |conn|
        conn.password = @password
        conn.client = self
        attach(conn)
      end
    end

    def attach(conn)
      @conn = conn
      @connecting = false
      @logger.debug '[FS-ESL] Connection established'
    end

    def connection_closed(_conn)
      @authenticated = false
      @connected = false
      @conn = nil

      if @closing
        @logger.debug '[FS-ESL] Connection closed (intentional)'
        return
      end

      unless @auto_reconnect
        @logger.warn '[FS-ESL] Connection lost (auto_reconnect disabled)'
        return
      end

      @logger.warn "[FS-ESL] Connection lost, reconnecting in #{@reconnect_interval}s..."
      EM.add_timer(@reconnect_interval) { open_socket unless @closing }
    end

    def close!
      @closing = true
      @connected = false
      @authenticated = false
      conn = @conn
      @conn = nil
      conn&.close_connection

      return unless @owns_reactor && EM.reactor_running?

      EM.next_tick do
        EM.stop
      rescue StandardError
        nil
      end
    end
    alias close close!

    def authenticated?
      @authenticated
    end
    alias ready? authenticated?

    # ------------------------------------------------------------------- frames

    def handle_frame(conn, frame)
      headers = frame[:headers]
      body = frame[:body].to_s
      content_type = frame[:content_type]

      case content_type
      when 'auth/request'
        @logger.debug '[FS-ESL] Auth requested'
        conn.send_command("auth #{@password}")
      when 'command/reply'
        handle_command_reply(headers)
      when 'api/response'
        response = Response.new(headers, body)
        callback = @api_callbacks.shift
        callback&.call(response)
      when 'text/event-plain'
        event_headers, event_body = Parser.parse_event(body)
        dispatch_event(event_headers, event_body)
      when 'text/event-json'
        event_headers, event_body = Parser.parse_event(body)
        dispatch_event(event_headers, event_body)
      when 'text/disconnect-notice'
        @logger.warn '[FS-ESL] Disconnected by server'
        @connected = false
        @authenticated = false
      else
        # Some FreeSWITCH builds send the first event without Content-Type.
        if body.include?('Event-Name:')
          event_headers, event_body = Parser.parse_event(body)
          dispatch_event(event_headers, event_body)
        end
      end
    end

    def handle_command_reply(headers)
      reply = headers['Reply-Text'].to_s

      if !@authenticated && reply.start_with?('+OK')
        @authenticated = true
        @connected = true
        @logger.info '[FS-ESL] Authenticated successfully'
        subscribe_default_events
        flush_queue
      elsif reply.start_with?('-ERR')
        @logger.error "[FS-ESL] Command failed: #{reply}"
        if !@authenticated
          @logger.error '[FS-ESL] Authentication failed, check password'
          close!
        end
      else
        @logger.debug "[FS-ESL] Reply: #{reply}"
        # FreeSWITCH generates the Job-UUID itself; the callback order is FIFO.
        if (job_uuid = reply[/Job-UUID:\s*(\S+)/, 1])
          callback = @bgapi_callbacks.shift
          @job_callbacks[job_uuid] = callback if callback
        end
      end
    end

    def dispatch_event(event, raw_body)
      event_name = event['Event-Name'].to_s

      if event_name == 'BACKGROUND_JOB'
        job_uuid = event['Job-UUID']
        callback = @job_callbacks.delete(job_uuid)
        callback&.call(Response.new(event, raw_body))
      end

      handlers = Array(@event_handlers[event_name.upcase]) + Array(@event_handlers['*'])
      handlers.each do |handler|
        begin
          handler.call(event)
        rescue StandardError => e
          @logger.error "[FS-ESL] Event handler error (#{event_name}): #{e.class}: #{e.message}"
        end
      end
    end

    # -------------------------------------------------------------------- events

    def subscribe_default_events
      @events = DEFAULT_EVENTS if @events.nil? || @events.empty?
      send_raw("event plain #{@events.join(' ')}")
    end

    # client.on('CHANNEL_ANSWER') { |event| ... }
    # client.on('*') { |event| ... }  — every subscribed event
    def on(event_name, &block)
      key = event_name.to_s.upcase
      @event_handlers[key] ||= []
      @event_handlers[key] << block
      self
    end

    # ------------------------------------------------------------------ commands

    def api(command, &block)
      @api_callbacks << block if block
      transmit("api #{command}")
    end

    def bgapi(command, &block)
      @bgapi_callbacks << block if block
      transmit("bgapi #{command}")
    end

    def send_command(command, job_uuid: nil)
      # Kept for backwards compatibility; Job-UUIDs are generated by FreeSWITCH.
      transmit(command)
    end

    def transmit(command)
      if @authenticated && @conn
        @conn.send_command(command)
      else
        @queue << command
      end
    end

    def send_raw(command)
      return unless @conn

      @conn.send_command(command)
    end

    def flush_queue
      return unless @conn

      queued = @queue.dup
      @queue.clear
      queued.each { |command| @conn.send_command(command) }
    end

    # --------------------------------------------------------------- call helpers

    # Places an outbound call. FreeSWITCH syntax:
    #
    #   originate <ultra-global><global>[per-leg]<call url> <exten>|&<app>(<args>)
    #             [<dialplan>] [<context>] [<cid_name>] [<cid_num>] [<timeout_sec>]
    #
    # Variable scopes (see src/switch_ivr_originate.c):
    #   ultra_vars: `<>` applied to every leg of the originate
    #   vars:       `{}` applied to the originated channel; also carries control
    #               variables (origination_caller_id_number, ignore_early_media,
    #               originate_timeout, ...)
    #   leg_vars:   `[]` session specific variables for this destination.
    #               NOTE: when a name exists in both, FreeSWITCH 1.11 keeps the
    #               `{}` value (verified live) — use distinct names per scope.
    #
    #   client.originate('user/1000', vars: { ignore_early_media: false })
    #   client.originate('sofia/gateway/agent/555', application: '&park()',
    #                    vars: { origination_caller_id_number: '1001' },
    #                    leg_vars: { effective_caller_id_name: 'Agent' })
    #   client.originate('sofia/gateway/agent/555', exten: '1000',
    #                    dialplan: 'XML', context: 'default',
    #                    cid_name: 'Agent', cid_num: '1001', timeout: 30)
    #
    # The callback receives a Response; +res.uuid+ is the originated channel.
    def originate(dialstring, application: nil, exten: nil, dialplan: nil, context: nil,
                  cid_name: nil, cid_num: nil, timeout: nil,
                  vars: {}, leg_vars: {}, ultra_vars: {}, &block)
      target =
        if application
          application.to_s.start_with?('&') ? application.to_s : "&#{application}"
        elsif exten
          [exten, dialplan || 'XML', context || 'default'].join(' ')
        else
          '&park()'
        end

      args = [target]
      if cid_name || cid_num || timeout
        # Positional args; FreeSWITCH collapses empty tokens, so skipped slots
        # must be the literal `undef` (see originate_function in mod_commands.c).
        args << (dialplan || 'XML')
        args << (context || 'default')
        args << (cid_name || 'undef')
        args << (cid_num || 'undef')
        args << timeout if timeout
      end

      bgapi("originate #{build_originate_args(dialstring, vars, leg_vars, ultra_vars)} " \
            "#{args.join(' ')}", &block)
    end

    # <ultra>{global}[leg]dialstring, in the order FreeSWITCH parses it.
    def build_originate_args(dialstring, vars = {}, leg_vars = {}, ultra_vars = {})
      "#{format_vars(ultra_vars, '<', '>')}#{format_vars(vars)}" \
        "#{format_vars(leg_vars, '[', ']')}#{dialstring}"
    end

    # `{key=value,key=value}` prefix for dial strings, '' when empty.
    def format_vars(vars, open = '{', close = '}')
      pairs = (vars || {}).reject { |_k, v| v.nil? }.map { |k, v| "#{k}=#{escape_var(v)}" }
      pairs.empty? ? '' : "#{open}#{pairs.join(',')}#{close}"
    end

    # Commas separate variables inside {}/[]/<>.
    def escape_var(value)
      value.to_s.gsub(',', '\\,')
    end

    def answer_call(uuid, &block)
      bgapi("uuid_answer #{uuid}", &block)
    end

    def kill(uuid, cause = 'NORMAL_CLEARING', &block)
      bgapi("uuid_kill #{uuid} #{cause}", &block)
    end
    alias hangup kill

    def bridge_calls(uuid1, uuid2, &block)
      bgapi("uuid_bridge #{uuid1} #{uuid2}", &block)
    end

    def play_file(uuid, file, leg = 'aleg', &block)
      bgapi("uuid_broadcast #{uuid} #{file} #{leg}", &block)
    end

    def stop_playback(uuid, &block)
      bgapi("uuid_break #{uuid} all", &block)
    end

    def set_var(uuid, name, value, &block)
      bgapi("uuid_setvar #{uuid} #{name} #{value}", &block)
    end

    def get_var(uuid, name, &block)
      api("uuid_getvar #{uuid} #{name}", &block)
    end

    def transfer(uuid, destination, dialplan = 'XML', context = 'default', &block)
      bgapi("uuid_transfer #{uuid} #{destination} #{dialplan} #{context}", &block)
    end

    def park(uuid, &block)
      bgapi("uuid_park #{uuid}", &block)
    end

    def status(&block)
      api('status', &block)
    end

    def channels(&block)
      api('show channels as json', &block)
    end
  end
end
