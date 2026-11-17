# frozen_string_literal: true

require_relative "lib/billionverify/version"

Gem::Specification.new do |spec|
  spec.name = "billionverify"
  spec.version = BillionVerify::VERSION
  spec.authors = ["BillionVerify"]
  spec.email = ["support@billionverify.com"]

  spec.summary = "Ruby client for the BillionVerify email verification API"
  spec.description = "Verify email addresses one at a time, in batches of 50 or as whole files, find the emails " \
                     "published on a company's site, manage webhooks and check your credit balance."
  spec.homepage = "https://github.com/BillionVerify/billionverify-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "documentation_uri" => "https://billionverify.com/docs"
  }

  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]
end
