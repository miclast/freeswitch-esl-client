# freeswitch-esl

A small, dependency-light Ruby client for the [FreeSWITCH](https://freeswitch.org/)
Event Socket Layer (`mod_event_socket`), with **inbound** and **outbound** modes.

- **Inbound** — your Ruby process connects to FreeSWITCH on `:8021`, subscribes to
  events and drives calls with `api` / `bgapi`.
- **Outbound** — FreeSWITCH dials into an embedded TCP server of yours
  (`<action application="socket" data="host:port async full"/>`), so call handling
  lives in Ruby instead of static dialplan XML. Ideal for building a B2BUA, IVR or
  dynamic routing service.

Verified live against FreeSWITCH 1.11 and Asterisk 20 in Docker, on Ruby 3.2+ and 4.0.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Inbound mode](#inbound-mode)
- [Originating calls](#originating-calls)
- [Outbound mode](#outbound-mode)
- [Threading and callbacks](#threading-and-callbacks)
- [Gotchas](#gotchas)
- [Development](#development)
- [License](#license)

## Requirements

- Ruby >= 3.2
- FreeSWITCH with `mod_event_socket` loaded
  (`conf/autoload_configs/event_socket.conf.xml`, default password `ClueCon`)
- Nothing else at runtime except [`eventmachine`](https://rubygems.org/gems/eventmachine)

## Installation

```ruby
# Gemfile
gem 'freeswitch-esl'
```

Or straight from Git while a release is not published yet:

```ruby
gem 'freeswitch-esl', git: 'https://github.com/miclast/freeswitch-esl.git', tag: 'v0.1.0'
```

Or from a local checkout:

```ruby
gem 'freeswitch-esl', path: '../freeswitch-esl'
```

Then:

```bash
bundle install
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
  client.on('*') { |event| puts event['Event-Name'] }   # catch-all

  client.connect           # inside a running reactor
  # client.connect!        # without a reactor: spawns its own thread

  EM.add_timer(1) do
    client.api('status') { |res| puts res.body }
  end
end
```

### Constructor options

| option | default | description |
| --- | --- | --- |
| `host` | `'127.0.0.1'` | ESL host |
| `port` | `8021` | ESL port |
| `password` | `'ClueCon'` | ESL password |
| `logger` | `Logger.new($stdout)` | any `Logger`-compatible object |
| `reconnect_interval` | `2` | seconds between reconnect attempts |
| `events` | `Client::DEFAULT_EVENTS` | events to subscribe to |
| `auto_reconnect` | `true` | reconnect automatically after a dropped connection |

Commands issued before authentication are queued and flushed once the socket is
ready; `client.ready?` tells whether that has happened.

### Commands

`api(command) { |res| … }` runs synchronously on the FreeSWITCH side and returns an
`api/response`; `bgapi(command) { |res| … }` returns immediately and resolves via a
`BACKGROUND_JOB` event. The gem maps the server-generated `Job-UUID` back to your
block, so callbacks stay in order even with concurrent jobs.

```ruby
client.bgapi('status') { |res| puts res.reply_text }              # +OK Job-UUID: …
client.api('show channels count') { |res| puts res.body }         # "2 total."
```

### Call helpers

Convenience wrappers over the API (all callback-based):

| helper | FreeSWITCH command |
| --- | --- |
| `answer_call(uuid)` | `uuid_answer` |
| `kill(uuid, cause = 'NORMAL_CLEARING')` / `hangup` | `uuid_kill` |
| `bridge_calls(uuid1, uuid2)` | `uuid_bridge` |
| `play_file(uuid, file, leg = 'aleg')` | `uuid_broadcast` |
| `stop_playback(uuid)` | `uuid_break … all` |
| `set_var(uuid, name, value)` | `uuid_setvar` |
| `get_var(uuid, name)` | `uuid_getvar` |
| `transfer(uuid, destination, dialplan = 'XML', context = 'default')` | `uuid_transfer` |
| `park(uuid)` | `uuid_park` |
| `status` | `status` |
| `channels` | `show channels as json` |

### Response object

| method | meaning |
| --- | --- |
| `success?` / `error?` | `+OK …` / `-ERR …` (works for bgapi too, where the text is in the body) |
| `reply_text` | `Reply-Text` header or the first body line |
| `uuid` | uuid from `+OK <uuid>` (handy for originate) |
| `job_uuid`, `event_name` | job/event identifiers |
| `body` / `output` | raw payload (API output, BACKGROUND_JOB output) |
| `[key]` | any header of the reply/event |

## Originating calls

`Client#originate` builds the FreeSWITCH `originate` command for you:

```ruby
client.originate('sofia/gateway/agent/555',
                 application: '&park()',           # or exten: '1000'
                 vars: {
                   origination_caller_id_number: '1001',
                   origination_caller_id_name: 'Agent',
                   ignore_early_media: 'false'
                 },
                 leg_vars: { effective_caller_id_name: 'Agent' }) do |res|
  if res.success?
    uuid = res.uuid                               # +OK <uuid>
  else
    warn res.reply_text                           # -ERR INVALID_GATEWAY
  end
end
```

A positional form maps to FreeSWITCH's `[dialplan] [context] [cid_name] [cid_num] [timeout_sec]`:

```ruby
client.originate('user/1000', cid_name: 'Support', cid_num: '1001', timeout: 30)
# => bgapi originate user/1000 &park() XML default Support 1001 30
```

Missing intermediate slots are sent as the literal `undef`, which FreeSWITCH turns
into `NULL`. Empty strings would be collapsed by its argv parser and shift the
remaining arguments (the timeout would silently become the caller ID).

### Variable scopes

FreeSWITCH accepts three prefixes on a dial string and they are not equivalent:

| scope | option | applies to |
| --- | --- | --- |
| `<...>` | `ultra_vars` | every leg of the originate |
| `{...}` | `vars` | the originated channel, plus originate control variables (`originate_timeout`, `ignore_early_media`, `origination_caller_id_*`, retries, `group_confirm_*`) |
| `[...]` | `leg_vars` | per-destination session variables |

They are emitted in that order: `<ultra>{global}[leg]dialstring`. Note that when the
same name appears in `{}` and `[]`, FreeSWITCH 1.11 keeps the `{}` value — use
distinct names per scope instead of relying on an override.

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
    session.bridge('sofia/gateway/trunk/555')
    session.hangup('NORMAL_CLEARING')
  end

  server.start
  # server.stop when shutting the application down
end
```

### How it works

1. FreeSWITCH connects and waits for the `connect` command — the server sends it
   automatically in `post_init`.
2. FreeSWITCH answers with a `command/reply` frame that also carries the channel
   data (`Unique-ID`, caller, destination, …); that becomes the `Session`.
3. The channel is parked. The session subscribes to its events and is driven with
   `sendmsg` (`execute`, `answer`, `bridge`, …).
4. Events are filtered by the session UUID (`Unique-ID`, `Bridge-A/B-Unique-ID`,
   `Other-Leg-Unique-ID`, `Originating-Leg-Unique-ID`), so concurrent calls on the
   same socket stay isolated.

### Session API

| group | methods |
| --- | --- |
| state | `uuid`, `caller_id_number`, `caller_id_name`, `destination_number`, `state`, `hangup_cause`, `answered?`, `ended?` |
| call control | `answer`, `pre_answer`, `ring_ready`, `hangup(cause)`, `bridge(dialstring)`, `transfer(extension, dialplan:, context:)`, `park` |
| media | `play(file)`, `play_and_get_digits(...)`, `read(...)`, `record(file, limit, ...)`, `speak(text, engine:, voice:)`, `sleep(ms)` |
| variables | `set(name, value)`, `export(name, value)`, `unset(name)`, `variable(name)`, `[](name)`, `headers` |
| signals | `send_dtmf(dtmf)`, `flush_dtmf` |
| escape hatch | `execute(app, args)`, `api(command)`, `bgapi(command)`, `send_command(raw)` |
| events | `on('DTMF') { … }`, `on('*') { … }` |

`Session::DEFAULT_EVENTS` can be tuned in the constant if you need fewer events per call.

## Threading and callbacks

EventMachine runs everything on a single reactor thread. Event handlers and
`api`/`bgapi` callbacks are invoked there, so keep them short: push work into a queue
(Sidekiq, a Ruby `Queue`, etc.) instead of doing blocking I/O inside a callback.

Calling `connect!` outside a reactor starts one owned by the client; `close!` stops
it. Inside an existing reactor use `connect` and manage the reactor yourself.

## Gotchas

- **Outbound sockets receive no events until they subscribe.** `listener_run` in
  `mod_event_socket.c` only delivers events after `event plain …`; the gem does this
  for you in `start_session`.
- **`bgapi` ignores a client-supplied `job-uuid=`.** FreeSWITCH generates its own and
  reports it in the reply; the gem parses and matches it.
- **Codecs must be in the bridge dial string** when a dialplan `set` is not honoured
  on the outbound leg:
  `session.bridge('{absolute_codec_string=PCMU,PCMA}sofia/gateway/trunk/555')`.
- **`Caller-Caller-ID-*` may be rewritten** by a gateway/profile; check `Caller-ANI`
  and `variable_origination_caller_id_*` when testing caller ID.
- **Frames are content-length aware.** The parser never splits on blank lines, because
  `BACKGROUND_JOB` bodies contain their own header block.

## Development

```bash
bundle install
bundle exec rspec        # 26 examples, no external services required
gem build freeswitch-esl.gemspec
```

The spec suite spins up fake ESL servers in-process, so FreeSWITCH does not need to
be running for the tests.

## Contributing

Issues and pull requests are welcome. Please run `bundle exec rspec` before opening a
PR and keep the public API backwards compatible within a minor version.

## License

Released under the [MIT License](LICENSE).
