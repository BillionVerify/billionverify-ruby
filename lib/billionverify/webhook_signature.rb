# frozen_string_literal: true

require "openssl"

module BillionVerify
  # Verifies the signature BillionVerify puts on webhook deliveries.
  #
  # A delivery carries +X-Webhook-Signature: sha256=<hex>+ and
  # +X-Webhook-Timestamp+. The signature is an HMAC-SHA256, keyed with the
  # webhook secret, over +"#{timestamp}.#{raw_body}"+.
  module WebhookSignature
    DEFAULT_TOLERANCE = 300

    module_function

    # @param payload [String] the raw request body, exactly as received
    # @param signature [String] the X-Webhook-Signature header
    # @param timestamp [String, Integer] the X-Webhook-Timestamp header (Unix seconds)
    # @param secret [String] the secret returned when the webhook was created
    # @param tolerance [Integer] largest accepted age in seconds; 0 skips the check
    # @param now [Time] the current time (for tests)
    # @return [Boolean]
    def valid?(payload:, signature:, timestamp:, secret:, tolerance: DEFAULT_TOLERANCE, now: Time.now)
      return false if signature.nil? || timestamp.nil? || secret.nil? || payload.nil?
      return false if secret.to_s.strip.empty?

      ts = Integer(timestamp.to_s, 10, exception: false)
      return false if ts.nil?
      return false if tolerance.to_i.positive? && (now.to_i - ts).abs > tolerance

      expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{payload}")
      given = signature.to_s.strip
      given = "sha256=#{given}" unless given.start_with?("sha256=")
      secure_compare(expected, given)
    end

    def secure_compare(a, b)
      return false unless a.bytesize == b.bytesize

      OpenSSL.fixed_length_secure_compare(a, b)
    end
  end
end
