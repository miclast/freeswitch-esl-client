module FreeswitchESL
  class Response
    attr_reader :headers, :body, :raw

    def initialize(headers = {}, body = '', raw = '')
      @headers = headers || {}
      @body = body || ''
      @raw = raw
    end

    def success?
      reply = reply_text.to_s
      return reply.start_with?('+OK') unless reply.empty?

      !body.to_s.start_with?('-ERR')
    end

    def error?
      !success?
    end

    def reply_text
      @headers['Reply-Text'] || @headers['reply-text']
    end

    def job_uuid
      @headers['Job-UUID'] || @headers['job-uuid']
    end

    def event_name
      @headers['Event-Name']
    end

    def [](key)
      @headers[key]
    end

    def to_s
      body.to_s
    end
  end
end
