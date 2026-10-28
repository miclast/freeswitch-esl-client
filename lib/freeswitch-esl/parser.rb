module FreeswitchESL
  # Parses ESL header blocks ("Key: value" lines) and reassembles complete
  # frames from a byte stream.
  #
  # ESL frames are always:
  #
  #   Key: value\n
  #   ...
  #   \n
  #   <body of Content-Length bytes>
  #
  # The body can itself contain blank lines (api/response output, event bodies),
  # so splitting the stream on "\n\n" is not correct — Content-Length must be
  # honoured.
  class Parser
    class << self
      def parse_headers(block)
        headers = {}
        return headers if block.nil?

        block.split(/\r?\n/).each do |line|
          next if line.empty?
          next unless line.include?(':')

          key, value = line.split(':', 2)
          headers[key.strip] = value.to_s.strip
        end
        headers
      end

      # Splits an event body into [headers, body]. FreeSWITCH events embed their
      # own header block and, for BACKGROUND_JOB, the command output follows a
      # blank line.
      def parse_event(raw)
        raw = raw.to_s
        idx = raw.index("\n\n")
        return [parse_headers(raw), ''] unless idx

        [parse_headers(raw[0...idx]), raw[(idx + 2)..] || '']
      end

      # Backwards compatible helper: parse a single complete frame string.
      def parse_frame(frame)
        frame = frame.to_s
        idx = frame.index("\n\n")
        if idx
          headers = parse_headers(frame[0...idx])
          body = frame[(idx + 2)..] || ''
        else
          headers = parse_headers(frame)
          body = ''
        end

        {
          headers: headers,
          body: body,
          content_type: headers['Content-Type'] || headers['content-type']
        }
      end
    end
  end

  # Incremental ESL frame reassembler.
  #
  #   framer = FreeswitchESL::Framer.new
  #   framer << data
  #   framer.each_frame { |frame| ... }
  class Framer
    def initialize
      @buffer = +''.b
    end

    def <<(data)
      @buffer << data.to_s.b
      self
    end

    def each_frame
      loop do
        header_end = @buffer.index("\n\n")
        break unless header_end

        headers = Parser.parse_headers(@buffer.byteslice(0, header_end))
        body_start = header_end + 2
        length = headers['Content-Length'].to_i
        length = 0 if length.negative?

        if length.zero?
          @buffer = @buffer.byteslice(body_start..) || +''.b
          yield({ headers: headers, body: +'', content_type: headers['Content-Type'] })
          next
        end

        break if @buffer.bytesize < body_start + length

        body = @buffer.byteslice(body_start, length)
        @buffer = @buffer.byteslice((body_start + length)..) || +''.b
        yield({ headers: headers, body: body, content_type: headers['Content-Type'] })
      end
    end

    def empty?
      @buffer.empty?
    end
  end
end
