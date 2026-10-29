require_relative 'lib/freeswitch-esl/version'

Gem::Specification.new do |spec|
  spec.name          = 'freeswitch-esl'
  spec.version       = FreeswitchESL::VERSION
  spec.authors       = ['Michael']
  spec.email         = ['michael@example.com']

  spec.summary       = 'Ruby client for the FreeSWITCH Event Socket Layer (inbound and outbound).'
  spec.description   = <<~DESC
    EventMachine-based client for the FreeSWITCH Event Socket Layer (mod_event_socket).
    Supports inbound mode (connect to port 8021, subscribe to events, run api/bgapi,
    auto-reconnect) and outbound mode (an embedded TCP server that FreeSWITCH dials into
    with the socket application, so call control lives in Ruby instead of dialplan XML).
    Includes a binary-safe ESL frame parser, a originate helper covering FreeSWITCH
    variable scopes and positional arguments, and per-channel outbound sessions.
  DESC
  spec.homepage      = 'https://github.com/YOUR_GITHUB_USER/freeswitch-esl'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata = {
    'homepage_uri'          => spec.homepage,
    'changelog_uri'         => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'documentation_uri'     => 'https://www.rubydoc.info/gems/freeswitch-esl',
    'rubygems_mfa_required' => 'true'
  }

  spec.files         = Dir.glob('{lib,exe}/**/*') + %w[README.md CHANGELOG.md LICENSE freeswitch-esl.gemspec]
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'eventmachine', '~> 1.2', '>= 1.2.7'
  spec.add_dependency 'logger', '>= 1.6'

  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
end
