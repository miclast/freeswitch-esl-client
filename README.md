# freeswitch-esl

Lightweight EventMachine-based Ruby client for FreeSWITCH `mod_event_socket` (ESL),
with **inbound** and **outbound** (socket application) support.

Tested against FreeSWITCH 1.11 (Docker), Ruby 3.2+ / 4.0.

## Features

- Inbound mode: one persistent ESL connection, auto-reconnect, event handlers
- Outbound mode: a TCP server that FreeSWITCH dials into (`socket host:port async full`),
  turning every call into a `FreeswitchESL::Outbound::Session`
- `api` / `bgapi` with callbacks (job-uuid tracked automatically)
- Binary-safe frame parser (`Content-Length` aware)
- No heavyweight dependency besides `eventmachine`

## Installation

```ruby
gem 'freeswitch-esl', git: 'https://github.com/USER/freeswitch-esl.git', tag: 'v0.1.0'
```

## Inbound mode

```ruby
require 'freeswitch-esl'
require 'eventmachine'

EM.run do
  client = FreeswitchESL::Client.new(
    host: '127.0.0.1',
    port: 8021,
    password: 'ClueCon'
  )

  client.on('CHANNEL_ANSWER') { |event| puts "answered #{event['Unique-ID']}" }
  client.on('CHANNEL_HANGUP_COMPLETE') { |event| puts "hung up: #{event['Hangup-Cause']}" }

  client.connect   # connects inside the running reactor

  EM.add_timer(1) do
    client.api('status') { |res| puts res.body }

    client.bgapi('originate {ignore_early_media=false}sofia/gateway/trunk/12345 &park()') do |res|
      puts res.success? ? 'originated' : "error: #{res.reply_text}"
    end
  end
end
```

Outside an EventMachine reactor call `client.connect!`, which spawns its own
reactor thread. `client.ready?` tells whether auth has completed; commands sent
earlier are queued and flushed after authentication.

## Outbound mode

FreeSWITCH makes the call, then hands the channel to your Ruby process:

```xml
<!-- dialplan -->
<extension name="app">
  <condition field="destination_number" expression="^9999$">
    <action application="socket" data="10.0.0.5:8084 async full"/>
  </condition>
</extension>
```

```ruby
require 'freeswitch-esl'
require 'eventmachine'

EM.run do
  server = FreeswitchESL.outbound_server(host: '0.0.0.0', port: 8084) do |session|
    puts "call from #{session.caller_id_number} to #{session.destination_number}"

    session.on('DTMF') { |e| puts "digit #{e['DTMF-Digit']}" }
    session.on('CHANNEL_HANGUP_COMPLETE') { |e| puts "cause #{e['Hangup-Cause']}" }

    session.answer
    session.play('ivr/ivr-welcome_to_freeswitch.wav')
    session.bridge('sofia/gateway/asterisk/9999')
    session.hangup('NORMAL_CLEARING')
  end

  server.start
end
```

### How it works

1. FreeSWITCH connects and waits for the `connect` command — the server sends it
   automatically in `post_init`.
2. FreeSWITCH answers with a `command/reply` frame that also carries the channel
   data (`Unique-ID`, caller, destination, …); that becomes the `Session`.
3. The channel is parked. The session subscribes to its events and is driven with
   `sendmsg` (`execute`, `answer`, `bridge`, …).

`Session` API: `answer`, `pre_answer`, `ring_ready`, `hangup`, `play`,
`play_and_get_digits`, `read`, `record`, `speak`, `bridge`, `transfer`, `park`,
`set`, `unset`, `export`, `sleep`, `send_dtmf`, `flush_dtmf`, `execute`, `api`,
`bgapi`, `variable(name)` / `[](name)`, `on(event)`, `answered?`, `ended?`.

Events are filtered by the session UUID, so concurrent calls on the same socket
instance stay isolated.

## Gotchas

- `bridge` dial string must carry the codecs when the dialplan `set` is not
  honoured: `session.bridge('{absolute_codec_string=PCMU,PCMA}sofia/gateway/asterisk/9999')`.
- FreeSWITCH ignores a client-supplied `job-uuid=` on `bgapi`; the gem maps the
  generated one from the reply.
- An outbound socket receives **no** events until it sends `event plain …`; the
  gem subscribes for you.

## Development

```bash
bundle install
bundle exec rspec
```

## License

MIT
