module FreeswitchESL
  class Error < StandardError; end
  class ConnectionError < Error; end
  class AuthError < Error; end
  class CommandError < Error; end
  class TimeoutError < Error; end
end
