require 'logger'

RSpec.describe FreeswitchESL::Outbound::Server do
  let(:logger) { Logger.new(File::NULL) }

  def start_server(port, stop_flag, ready, &handler)
    Thread.new do
      EM.run do
        server = described_class.new(host: '127.0.0.1', port: port, logger: logger, &handler)
        server.start
        ready << true
        EM.add_periodic_timer(0.05) { EM.stop if stop_flag.call }
      end
    end
  end

  it 'performs the async handshake and turns channel data into a Session' do
    port = free_port
    sessions = Queue.new
    ready = Queue.new
    stopped = false

    thread = start_server(port, -> { stopped }, ready) do |session|
      sessions << session
      session.answer
      session.sleep(100)
      session.hangup('NORMAL_CLEARING')
    end

    ready.pop
    socket = TCPSocket.new('127.0.0.1', port)
    reader = ESLReader.new(socket)

    # 1. FreeSWITCH waits for "connect" before sending anything (mod_event_socket.c)
    expect(reader.read_command).to eq('connect')

    # 2. FreeSWITCH replies with a command/reply frame that also carries channel data
    socket.write(build_frame({
                               'Content-Type' => 'command/reply',
                               'Reply-Text' => '+OK',
                               'Socket-Mode' => 'async',
                               'Control' => 'full',
                               'Unique-ID' => 'uuid-0001',
                               'Channel-State' => 'CS_EXECUTE',
                               'Caller-Caller-ID-Number' => '1000',
                               'Caller-Caller-ID-Name' => 'Alice',
                               'Caller-Destination-Number' => '9999',
                               'Caller-Context' => 'default',
                               'variable_sip_from_user' => '1000'
                             }))

    wait_until { !sessions.empty? }
    session = sessions.pop

    expect(session.uuid).to eq('uuid-0001')
    expect(session.caller_id_number).to eq('1000')
    expect(session.caller_id_name).to eq('Alice')
    expect(session.destination_number).to eq('9999')
    expect(session.variable('sip_from_user')).to eq('1000')
    expect(session.state).to eq('CS_EXECUTE')
    expect(session.answered?).to be(true)

    # 3. The session subscribes to its own events (outbound sockets get nothing without this)
    subscription = reader.read_command
    expect(subscription).to start_with('event plain ')
    expect(subscription).to include('CHANNEL_HANGUP_COMPLETE')

    # 4. The handler's commands are sent to FreeSWITCH as sendmsg frames, in order
    first = reader.read_command
    expect(first).to include('execute-app-name: answer')
    expect(first).to include('call-command: execute')

    second = reader.read_command
    expect(second).to include('execute-app-name: sleep')
    expect(second).to include('execute-app-arg: 100')

    third = reader.read_command
    expect(third).to include('execute-app-name: hangup')
    expect(third).to include('execute-app-arg: NORMAL_CLEARING')
  ensure
    socket&.close
    stopped = true
    thread&.join(5)
  end

  it 'dispatches async events to the session handlers' do
    port = free_port
    ready = Queue.new
    registered = Queue.new
    events = Queue.new
    sessions = Queue.new
    stopped = false

    thread = start_server(port, -> { stopped }, ready) do |session|
      sessions << session
      session.on('DTMF') { |event| events << event }
      session.on('CHANNEL_HANGUP_COMPLETE') { |event| events << event }
      registered << true
    end

    ready.pop
    socket = TCPSocket.new('127.0.0.1', port)
    reader = ESLReader.new(socket)
    expect(reader.read_command).to eq('connect')

    socket.write(build_frame({
                               'Content-Type' => 'command/reply',
                               'Reply-Text' => '+OK',
                               'Unique-ID' => 'uuid-0002',
                               'Channel-State' => 'CS_EXECUTE',
                               'Caller-Caller-ID-Number' => '1000',
                               'Caller-Destination-Number' => '9999'
                             }))

    registered.pop
    session = sessions.pop
    expect(reader.read_command).to start_with('event plain ')

    socket.write(build_frame({ 'Content-Type' => 'text/event-plain' },
                             "Event-Name: DTMF\nDTMF-Digit: 5\nUnique-ID: uuid-0002\n"))

    wait_until { !events.empty? }
    dtmf = events.pop
    expect(dtmf['Event-Name']).to eq('DTMF')
    expect(dtmf['DTMF-Digit']).to eq('5')

    # An event for another channel must not reach this session
    socket.write(build_frame({ 'Content-Type' => 'text/event-plain' },
                             "Event-Name: CHANNEL_HANGUP_COMPLETE\nHangup-Cause: NORMAL_CLEARING\nUnique-ID: uuid-other\n"))
    sleep 0.2
    expect(events.empty?).to be(true)
    expect(session.ended?).to be(false)

    socket.write(build_frame({ 'Content-Type' => 'text/event-plain' },
                             "Event-Name: CHANNEL_HANGUP_COMPLETE\nHangup-Cause: NORMAL_CLEARING\nUnique-ID: uuid-0002\n"))

    wait_until { session.ended? }
    expect(session.hangup_cause).to eq('NORMAL_CLEARING')
  ensure
    socket&.close
    stopped = true
    thread&.join(5)
  end
end
