require 'freeswitch-esl/version'
require 'freeswitch-esl/errors'
require 'freeswitch-esl/parser'
require 'freeswitch-esl/response'
require 'freeswitch-esl/connection'
require 'freeswitch-esl/client'
require 'freeswitch-esl/outbound/connection'
require 'freeswitch-esl/outbound/session'
require 'freeswitch-esl/outbound/server'

module FreeswitchESL
  class << self
    def new(**options)
      Client.new(**options)
    end

    def outbound_server(**options, &block)
      Outbound::Server.new(**options, &block)
    end

    def start_outbound_server(**options, &block)
      Outbound::Server.new(**options, &block).start
    end
  end
end
