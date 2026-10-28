require 'socket'
require 'freeswitch-esl'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
  config.default_formatter = 'doc' if config.files_to_run.one?
end

# Reads complete ESL frames from a TCP socket using the gem's own framer.
class ESLReader
  def initialize(socket)
    @socket = socket
    @framer = FreeswitchESL::Framer.new
    @pending = []
    @raw = +''
  end

  def read_frame(timeout: 5)
    deadline = Time.now + timeout
    loop do
      return @pending.shift unless @pending.empty?

      @framer.each_frame { |frame| @pending << frame }
      return @pending.shift unless @pending.empty?

      raise "timeout waiting for ESL frame (buffer: #{@framer.inspect})" if Time.now > deadline

      next unless IO.select([@socket], nil, nil, 0.1)

      begin
        @framer << @socket.readpartial(4096)
      rescue EOFError
        raise 'connection closed while waiting for ESL frame'
      end
    end
  end

  # Reads raw command text terminated by a blank line.
  def read_command(timeout: 5)
    deadline = Time.now + timeout
    loop do
      if (idx = @raw.index("\n\n"))
        command = @raw[0...idx]
        @raw = @raw[(idx + 2)..] || +''
        return command
      end

      raise "timeout waiting for command (buffer: #{@raw.inspect})" if Time.now > deadline
      next unless IO.select([@socket], nil, nil, 0.1)

      begin
        @raw << @socket.readpartial(4096)
      rescue EOFError
        raise "connection closed while waiting for command (buffer: #{@raw.inspect})"
      end
    end
  end
end

def build_frame(headers, body = '')
  header_block = headers.map { |k, v| "#{k}: #{v}" }.join("\n")
  header_block += "\nContent-Length: #{body.bytesize}" unless body.empty?
  "#{header_block}\n\n#{body}"
end

def wait_until(timeout: 5)
  deadline = Time.now + timeout
  until yield
    raise 'condition not met in time' if Time.now > deadline

    sleep 0.01
  end
end

def free_port
  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  server.close
  port
end
