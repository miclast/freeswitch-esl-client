require 'logger'

RSpec.describe FreeswitchESL::Client do
  let(:logger) { Logger.new(File::NULL) }

  # Minimal fake mod_event_socket server.
  def run_fake_server(tcp, commands)
    Thread.new do
      socket = tcp.accept
      reader = ESLReader.new(socket)

      socket.write("Content-Type: auth/request\n\n")

      loop do
        command = begin
          reader.read_command(timeout: 10)
        rescue StandardError
          break
        end
        commands << command

        case command
        when /\Aauth /
          socket.write(build_frame({ 'Content-Type' => 'command/reply',
                                     'Reply-Text' => '+OK accepted' }))
        when /\Aevent plain/
          socket.write(build_frame({ 'Content-Type' => 'command/reply',
                                     'Reply-Text' => '+OK event listener enabled plain' }))
          # Async event straight after subscribing
          socket.write(build_frame({ 'Content-Type' => 'text/event-plain' },
                                   "Event-Name: CHANNEL_CREATE\nUnique-ID: uuid-event-1\n" \
                                   "Caller-Destination-Number: 9999\n"))
        when /\Aapi status/
          socket.write(build_frame({ 'Content-Type' => 'api/response' },
                                   "UP 0 years, 1 day, 2 hours\n"))
        when /\Abgapi /
          # FreeSWITCH generates the Job-UUID and reports it in the reply.
          job_uuid = "srv-job-#{commands.size}"
          socket.write(build_frame({ 'Content-Type' => 'command/reply',
                                     'Reply-Text' => "+OK Job-UUID: #{job_uuid}" }))
          # Real FreeSWITCH embeds event headers + a blank line + command output.
          event_body = "Event-Name: BACKGROUND_JOB\nJob-UUID: #{job_uuid}\n" \
                       "Job-Command: status\nContent-Type: text/plain\n" \
                       "Content-Length: 20\n\nUP 0 years, 1 day\n"
          socket.write(build_frame({ 'Content-Type' => 'text/event-plain' }, event_body))
        end
      end
    ensure
      socket&.close
    end
  end

  it 'authenticates, subscribes, runs api/bgapi and dispatches events' do
    tcp = TCPServer.new('127.0.0.1', 0)
    port = tcp.addr[1]
    commands = Queue.new
    server = run_fake_server(tcp, commands)

    api_response = nil
    job_response = nil
    events = []

    EM.run do
      client = described_class.new(host: '127.0.0.1', port: port, password: 'ClueCon',
                                  logger: logger, reconnect_interval: 1)

      client.on('CHANNEL_CREATE') { |event| events << event }
      client.connect!

      EM.add_timer(1.0) do
        expect(client.ready?).to be(true)
        client.api('status') { |res| api_response = res }
      end

      EM.add_timer(1.5) { client.bgapi('status') { |res| job_response = res } }

      EM.add_timer(3.0) do
        client.close!
        EM.stop
      end
    end

    server.join(5)
    tcp.close

    expect(api_response).not_to be_nil
    expect(api_response.body.strip).to eq('UP 0 years, 1 day, 2 hours')
    expect(job_response).not_to be_nil
    expect(job_response.body.strip).to eq('UP 0 years, 1 day')

    expect(events.size).to eq(1)
    expect(events.first['Event-Name']).to eq('CHANNEL_CREATE')
    expect(events.first['Unique-ID']).to eq('uuid-event-1')

    sent = []
    sent << commands.pop until commands.empty?
    expect(sent).to include('auth ClueCon')
    expect(sent.any? { |c| c.start_with?('event plain') }).to be(true)
    expect(sent).to include('api status')
    expect(sent).to include('bgapi status')
  end

  it 'queues commands sent before authentication' do
    tcp = TCPServer.new('127.0.0.1', 0)
    port = tcp.addr[1]
    commands = Queue.new
    received = nil

    slow_server = Thread.new do
      socket = tcp.accept
      reader = ESLReader.new(socket)
      sleep 0.5 # delay the auth request on purpose
      socket.write("Content-Type: auth/request\n\n")
      socket.write(build_frame({ 'Content-Type' => 'command/reply', 'Reply-Text' => '+OK accepted' }))
      loop do
        command = begin
          reader.read_command(timeout: 5)
        rescue StandardError
          break
        end
        commands << command
        socket.write(build_frame({ 'Content-Type' => 'api/response' }, 'OK')) if command.start_with?('api ')
      end
    ensure
      socket&.close
    end

    EM.run do
      client = described_class.new(host: '127.0.0.1', port: port, password: 'ClueCon', logger: logger)
      client.connect!
      # Sent before the connection is even authenticated
      client.api('status') { |res| received = res }

      EM.add_timer(3) do
        client.close!
        EM.stop
      end
    end

    slow_server.join(5)
    tcp.close

    expect(received).not_to be_nil
    expect(received.body).to eq('OK')
  end
end
