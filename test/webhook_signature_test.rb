# frozen_string_literal: true

require "test_helper"

class WebhookSignatureTest < Minitest::Test
  SECRET = "5c609e6893ab3b65ce8940549a030bc165762fe171e0b38f880bd570099619bf"
  BODY = '{"event":"file.completed","data":{"job_id":"j1"}}'

  def sign(body, timestamp, secret = SECRET)
    "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
  end

  def now
    Time.at(1_700_000_000)
  end

  def valid?(**over)
    args = { payload: BODY, signature: sign(BODY, "1700000000"), timestamp: "1700000000", secret: SECRET, now: now }
    BillionVerify::WebhookSignature.valid?(**args.merge(over))
  end

  def test_accepts_a_correct_signature
    assert valid?
    assert valid?(timestamp: 1_700_000_000)
  end

  def test_rejects_a_changed_body_secret_or_timestamp
    refute valid?(payload: BODY + " ")
    refute valid?(secret: "other")
    refute valid?(timestamp: "1700000001")
  end

  def test_rejects_old_and_future_timestamps
    refute valid?(now: Time.at(1_700_000_000 + 301))
    refute valid?(now: Time.at(1_700_000_000 - 301))
    assert valid?(now: Time.at(1_700_000_000 + 300))
  end

  def test_tolerance_zero_skips_the_time_check
    assert valid?(now: Time.at(1_800_000_000), tolerance: 0)
  end

  def test_rejects_missing_or_malformed_input
    refute valid?(signature: nil)
    refute valid?(timestamp: nil)
    refute valid?(timestamp: "yesterday")
    refute valid?(signature: "sha256=")
    refute valid?(signature: "sha256=zz")
  end

  def test_accepts_a_bare_hex_digest
    assert valid?(signature: sign(BODY, "1700000000").delete_prefix("sha256="))
  end

  def test_top_level_and_client_shortcuts
    args = { payload: BODY, signature: sign(BODY, "1700000000"), timestamp: "1700000000", secret: SECRET, now: now }
    assert BillionVerify.verify_webhook_signature(**args)
    assert BillionVerify::Client.new(api_key: "k").verify_webhook_signature(**args)
  end
end
