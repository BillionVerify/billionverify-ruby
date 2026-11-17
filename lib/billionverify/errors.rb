# frozen_string_literal: true

module BillionVerify
  # Base class for every error the SDK raises.
  class Error < StandardError
    attr_reader :code, :status_code, :details, :request_id

    def initialize(message = "BillionVerify error", code: "UNKNOWN_ERROR", status_code: 0, details: nil, request_id: nil)
      super(message)
      @code = code
      @status_code = status_code
      @details = details
      @request_id = request_id
    end

    def to_s
      "#{code}: #{super}"
    end
  end

  # 401: the API key is missing or invalid.
  class AuthenticationError < Error
    def initialize(message = "Invalid or missing API key", **opts)
      super(message, **{ code: "INVALID_API_KEY", status_code: 401 }.merge(opts))
    end
  end

  # 400: the request was rejected as invalid (also raised locally before sending).
  class ValidationError < Error
    def initialize(message = "Invalid request", **opts)
      super(message, **{ code: "INVALID_REQUEST", status_code: 400 }.merge(opts))
    end
  end

  # 402: the account has too few credits for the request.
  class InsufficientCreditsError < Error
    def initialize(message = "Insufficient credits", **opts)
      super(message, **{ code: "INSUFFICIENT_CREDITS", status_code: 402 }.merge(opts))
    end
  end

  # 404: the job, webhook, search or batch does not exist.
  class NotFoundError < Error
    def initialize(message = "Resource not found", **opts)
      super(message, **{ code: "NOT_FOUND", status_code: 404 }.merge(opts))
    end
  end

  # 429: still rate limited after the retries ran out. +retry_after+ is in seconds.
  class RateLimitError < Error
    attr_reader :retry_after

    def initialize(message = "Rate limit exceeded", retry_after: 0, **opts)
      super(message, **{ code: "RATE_LIMIT_EXCEEDED", status_code: 429 }.merge(opts))
      @retry_after = retry_after
    end
  end

  # The request or a wait helper ran out of time.
  class TimeoutError < Error
    def initialize(message = "Request timed out", **opts)
      super(message, **{ code: "TIMEOUT", status_code: 504 }.merge(opts))
    end
  end

  # The connection failed before a response arrived.
  class NetworkError < Error
    def initialize(message = "Network error", **opts)
      super(message, **{ code: "NETWORK_ERROR", status_code: 0 }.merge(opts))
    end
  end
end
