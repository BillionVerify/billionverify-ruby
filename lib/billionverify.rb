# frozen_string_literal: true

require "billionverify/version"
require "billionverify/errors"
require "billionverify/object"
require "billionverify/webhook_signature"
require "billionverify/client"

# Ruby client for the BillionVerify email verification API.
module BillionVerify
  # Shortcut for BillionVerify::WebhookSignature.valid?.
  def self.verify_webhook_signature(**args)
    WebhookSignature.valid?(**args)
  end
end
