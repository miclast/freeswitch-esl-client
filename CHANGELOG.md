# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-29

First public release. Verified live against FreeSWITCH 1.11 and Asterisk 20 in Docker,
on Ruby 3.2+ and 4.0.

The gem is published as `freeswitch-esl-client` because `freeswitch-esl` was already
taken on RubyGems. The library name is unchanged: `require 'freeswitch-esl'` and the
`FreeswitchESL` namespace. `require 'freeswitch-esl-client'` is available as a shim.

### Added

- **Inbound mode** — `FreeswitchESL::Client` connects to `mod_event_socket` (default
  `127.0.0.1:8021`), authenticates, subscribes to events, auto-reconnects, and exposes
  `api` / `bgapi` with callbacks.
- **Outbound mode** — `FreeswitchESL.outbound_server` starts a TCP server that
  FreeSWITCH dials into (`socket host:port async full`). Every call becomes a
  `FreeswitchESL::Outbound::Session` with `answer`, `play`, `bridge`, `transfer`,
  `set`, `export`, `speak`, `record`, `read`, `send_dtmf`, `execute`, `api`, `bgapi`.
- Output-side `connect` handshake and automatic event subscription for outbound
  sockets, with per-call event filtering by `Unique-ID`.
- `Client#originate` with `application:`, `exten:`/`dialplan:`/`context:`,
  positional `cid_name`/`cid_num`/`timeout`, and the three FreeSWITCH variable
  scopes: `ultra_vars:` (`<>`), `vars:` (`{}`), `leg_vars:` (`[]`).
- Binary-safe `Framer` that honours `Content-Length` and never splits frames on
  blank lines, plus a parser for nested BACKGROUND_JOB bodies.
- `Response` helpers: `success?`, `error?`, `reply_text`, `uuid`, `job_uuid`,
  `event_name`, `body` / `output`.
- Call helpers on the inbound client: `answer_call`, `kill`/`hangup`,
  `bridge_calls`, `play_file`, `stop_playback`, `set_var`, `get_var`, `transfer`,
  `park`, `status`, `channels`.
- RSpec suite (26 examples) with a fake ESL server covering inbound, outbound and
  originate command building.
