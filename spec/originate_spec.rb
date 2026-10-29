require 'logger'

RSpec.describe 'FreeswitchESL::Client#originate' do
  let(:logger) { Logger.new(File::NULL) }
  subject(:client) { FreeswitchESL::Client.new(host: '127.0.0.1', port: 1, logger: logger) }

  # Command arguments are the interesting part; the target/positional tail is
  # appended by #originate itself.
  def args(*call_args, **opts)
    client.build_originate_args(*call_args, **opts)
  end

  describe '#build_originate_args' do
    it 'returns the bare dial string without variables' do
      expect(args('user/1000')).to eq('user/1000')
    end

    it 'wraps global variables in {}' do
      expect(args('user/1000', { ignore_early_media: 'false' }))
        .to eq('{ignore_early_media=false}user/1000')
    end

    it 'orders scopes as <ultra>{global}[leg], the way FreeSWITCH parses them' do
      expect(args('user/1000',
                  { global: 'g' },
                  { leg: 'l' },
                  { ultra: 'u' }))
        .to eq('<ultra=u>{global=g}[leg=l]user/1000')
    end

    it 'joins several variables with commas' do
      expect(args('user/1000', { a: 1, b: 2 })).to eq('{a=1,b=2}user/1000')
    end

    it 'drops nil values' do
      expect(args('user/1000', { a: 1, b: nil })).to eq('{a=1}user/1000')
    end

    it 'escapes commas inside values' do
      expect(args('user/1000', { a: 'x,y' })).to eq('{a=x\\,y}user/1000')
    end

    it 'returns the dial string unchanged for empty scopes' do
      expect(args('user/1000', {}, {}, {})).to eq('user/1000')
    end
  end

  describe 'the originate command sent to FreeSWITCH' do
    # Fake mod_event_socket server that records commands and answers originate.
    def run_fake_server(tcp, commands, originate_reply)
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
          when /\Abgapi originate/
            job_uuid = 'srv-job-1'
            socket.write(build_frame({ 'Content-Type' => 'command/reply',
                                       'Reply-Text' => "+OK Job-UUID: #{job_uuid}" }))
            body = "Event-Name: BACKGROUND_JOB\nJob-UUID: #{job_uuid}\n" \
                   "Job-Command: originate\nContent-Type: text/plain\n\n#{originate_reply}\n"
            socket.write(build_frame({ 'Content-Type' => 'text/event-plain' }, body))
          end
        end
      ensure
        socket&.close
      end
    end

    def originate_and_capture(originate_reply, &block)
      tcp = TCPServer.new('127.0.0.1', 0)
      port = tcp.addr[1]
      commands = Queue.new
      server = run_fake_server(tcp, commands, originate_reply)

      response = nil
      EM.run do
        client = FreeswitchESL::Client.new(host: '127.0.0.1', port: port, password: 'ClueCon',
                                           logger: Logger.new(File::NULL), reconnect_interval: 1)
        client.connect!
        EM.add_timer(1.0) { block.call(client) { |res| response = res } }
        EM.add_timer(2.5) do
          client.close!
          EM.stop
        end
      end

      server.join(5)
      tcp.close

      sent = []
      sent << commands.pop until commands.empty?
      [response, sent.grep(/\Abgapi originate/).first]
    end

    it 'defaults to &park() when no application or extension is given' do
      response, command = originate_and_capture('+OK aaaa-bbbb') { |c, &blk| c.originate('user/1000', &blk) }

      expect(command).to eq('bgapi originate user/1000 &park()')
      expect(response.success?).to be(true)
      expect(response.uuid).to be_nil # body is not a plain uuid
    end

    it 'parses the uuid from the BACKGROUND_JOB output' do
      uuid = '7c3a2d1e-0a9b-4c8d-9e5f-123456789abc'
      _, command = originate_and_capture("+OK #{uuid}") do |c, &blk|
        c.originate('loopback/9998/default', exten: '9998', &blk)
      end

      expect(command).to eq('bgapi originate loopback/9998/default 9998 XML default')
    end

    it 'prefixes applications with & and keeps their arguments' do
      _, command = originate_and_capture('+OK x') do |c, &blk|
        c.originate('user/1000', application: 'playback(welcome.wav)', &blk)
      end

      expect(command).to eq('bgapi originate user/1000 &playback(welcome.wav)')
    end

    it 'sends globals, per-leg vars and the application in the right order' do
      _, command = originate_and_capture('+OK x') do |c, &blk|
        c.originate('sofia/gateway/agent/555',
                    application: '&park()',
                    ultra_vars: { u: '1' },
                    vars: { origination_caller_id_number: '1001', ignore_early_media: 'false' },
                    leg_vars: { effective_caller_id_name: 'Agent' }, &blk)
      end

      expect(command).to eq(
        'bgapi originate <u=1>{origination_caller_id_number=1001,ignore_early_media=false}' \
        '[effective_caller_id_name=Agent]sofia/gateway/agent/555 &park()'
      )
    end

    it 'fills positional arguments and uses undef for skipped slots' do
      _, command = originate_and_capture('+OK x') do |c, &blk|
        c.originate('user/1000', cid_name: 'Agent', cid_num: '1001', timeout: 30, &blk)
      end

      expect(command).to eq('bgapi originate user/1000 &park() XML default Agent 1001 30')
    end

    it 'uses undef placeholders when only the timeout is given' do
      _, command = originate_and_capture('+OK x') do |c, &blk|
        c.originate('user/1000', timeout: 25, &blk)
      end

      expect(command).to eq('bgapi originate user/1000 &park() XML default undef undef 25')
    end

    it 'reports -ERR originate replies as failures without a uuid' do
      response, = originate_and_capture('-ERR INVALID_GATEWAY') do |c, &blk|
        c.originate('sofia/gateway/nope/1', &blk)
      end

      expect(response.success?).to be(false)
      expect(response.uuid).to be_nil
      expect(response.reply_text).to eq('-ERR INVALID_GATEWAY')
    end
  end
end
