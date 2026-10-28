require_relative 'lib/freeswitch-esl/version'

Gem::Specification.new do |spec|
  spec.name          = 'freeswitch-esl'
  spec.version       = FreeswitchESL::VERSION
  spec.authors       = ['Michael']
  spec.email         = ['michael@example.com']

  spec.summary       = 'Ruby client for FreeSWITCH Event Socket Layer (mod_event_socket)'
  spec.description   = 'Lightweight EventMachine-based client for FreeSWITCH ESL with support for api/bgapi, events, auto-reconnect.'
  spec.homepage      = 'https://github.com/'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.files         = Dir.glob('{lib,exe}/**/*') + %w[README.md LICENSE freeswitch-esl.gemspec]
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_dependency 'eventmachine', '~> 1.2', '>= 1.2.7'
  spec.add_dependency 'logger', '>= 1.6'

  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
end
