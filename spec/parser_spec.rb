RSpec.describe FreeswitchESL::Parser do
  describe '.parse_headers' do
    it 'parses simple key/value headers' do
      headers = described_class.parse_headers("Content-Type: command/reply\nReply-Text: +OK accepted")
      expect(headers).to eq('Content-Type' => 'command/reply', 'Reply-Text' => '+OK accepted')
    end

    it 'handles CRLF line endings and values containing colons' do
      headers = described_class.parse_headers("Channel-Name: sofia/internal/1000\r\nHangup-Cause: NORMAL_CLEARING:OK")
      expect(headers['Channel-Name']).to eq('sofia/internal/1000')
      expect(headers['Hangup-Cause']).to eq('NORMAL_CLEARING:OK')
    end

    it 'ignores blank lines and lines without a colon' do
      headers = described_class.parse_headers("A: 1\n\nB: 2\ngarbage")
      expect(headers).to eq('A' => '1', 'B' => '2')
    end
  end

  describe '.parse_frame' do
    it 'splits headers and body' do
      frame = described_class.parse_frame("Content-Type: api/response\nContent-Length: 5\n\nhello")
      expect(frame[:content_type]).to eq('api/response')
      expect(frame[:body]).to eq('hello')
    end
  end
end

RSpec.describe FreeswitchESL::Framer do
  subject(:framer) { described_class.new }

  def frames_from(*chunks)
    result = []
    chunks.each do |chunk|
      framer << chunk
      framer.each_frame { |frame| result << frame }
    end
    result
  end

  it 'yields a header-only frame' do
    frames = frames_from("Content-Type: command/reply\nReply-Text: +OK\n\n")
    expect(frames.size).to eq(1)
    expect(frames.first[:headers]['Reply-Text']).to eq('+OK')
    expect(frames.first[:body]).to eq('')
  end

  it 'honours Content-Length instead of splitting on blank lines' do
    body = "Event-Name: CHANNEL_ANSWER\n\nUnique-ID: abc\n"
    raw = "Content-Type: text/event-plain\nContent-Length: #{body.bytesize}\n\n#{body}"

    frames = frames_from(raw)
    expect(frames.size).to eq(1)
    expect(frames.first[:body]).to eq(body)
    expect(frames.first[:content_type]).to eq('text/event-plain')
  end

  it 'waits for the complete body when the frame arrives in pieces' do
    body = 'UP 0 years, 1 day'
    raw = "Content-Type: api/response\nContent-Length: #{body.bytesize}\n\n#{body}"

    first = frames_from(raw[0, 20])
    expect(first).to be_empty

    rest = frames_from(raw[20..])
    expect(rest.size).to eq(1)
    expect(rest.first[:body]).to eq(body)
  end

  it 'parses several frames from one chunk' do
    raw = "Content-Type: command/reply\nReply-Text: +OK\n\n" \
          "Content-Type: api/response\nContent-Length: 2\n\nok"
    frames = frames_from(raw)
    expect(frames.map { |f| f[:content_type] }).to eq(%w[command/reply api/response])
  end
end
