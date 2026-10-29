module FreeswitchESL
  class Response
    attr_reader :headers, :body, :raw

    def initialize(headers = {}, body = '', raw = '')
      @headers = headers || {}
      @body = body || ''
      @raw = raw
    end

    # bgapi responses carry the command output in the body and have no
    # Reply-Text header, so both are taken into account.
    def success?
      reply = reply_text.to_s
      return false if reply.start_with?('-')
      return true if reply.start_with?('+OK')

      !body.to_s.lstrip.start_with?('-')
    end

    def error?
      !success?
    end

    def reply_text
      @headers['Reply-Text'] || @headers['reply-text'] || first_body_line
    end

    def job_uuid
      @headers['Job-UUID'] || @headers['job-uuid']
    end

    def event_name
      @headers['Event-Name']
    end

    # UUID returned by `originate` (`+OK <uuid>`) — nil for other commands.
    def uuid
      reply_text.to_s[/\+OK\s+([0-9a-f-]{36})/, 1]
    end

    def [](key)
      @headers[key]
    end

    # The command output (alias of #body, reads better for api/bgapi).
    def output
      body
    end

    def to_s
      body.to_s
    end

    private

    def first_body_line
      body.to_s.lines.first.to_s.strip
    end
  end
end
