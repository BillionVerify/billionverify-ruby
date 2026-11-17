# BillionVerify for Ruby

Ruby client for the [BillionVerify](https://billionverify.com) email verification API. It covers every operation of the API: single and batch verification, the free disposable check, file verification, credits, webhooks, domain search and the health check. It uses only the Ruby standard library (`net/http`), so it adds no runtime dependency.

API reference: <https://billionverify.com/docs>

## Installation

```sh
gem install billionverify
```

or in your `Gemfile`:

```ruby
gem "billionverify", "~> 1.0"
```

Ruby 3.1 or newer.

## Quick start

```ruby
require "billionverify"

client = BillionVerify::Client.new(api_key: ENV.fetch("BILLIONVERIFY_API_KEY"))

result = client.verify("user@example.com")
result.status          # => "valid"
result.is_deliverable  # => true
result.score           # => 0.95
result.credits_used    # => 1
```

Every method returns the `data` of the API response as a `BillionVerify::Object`. Read fields as methods (`result.status`), with `[]` (`result[:status]`) or turn it into a Hash with `to_h`. A field that is not in the response reads as `nil`, and fields the SDK has never heard of still work, so a new API field needs no new gem.

### Configuration

```ruby
client = BillionVerify::Client.new(
  api_key: "your-api-key",
  base_url: "https://api.billionverify.com", # default
  timeout: 30,                               # seconds per request, default 30
  retries: 3                                 # total attempts for 429/500/502/503, default 3
)
```

## Verify emails

```ruby
# One address. Options you leave out are not sent, so the server default applies.
client.verify("user@example.com", check_smtp: true, force_refresh: false, include_domain_reputation: true)

# Up to 50 addresses in one synchronous request.
batch = client.verify_batch(%w[a@example.com b@example.com])
batch.total_emails                       # => 2
batch.results.map(&:status)              # => ["valid", "invalid"]
batch.deliverability_buckets.not_deliverable

# Free check against the disposable-domain table.
client.check_disposable("someone@mailinator.com").is_disposable          # POST
client.check_disposable_via_query("someone@mailinator.com").is_disposable # GET
```

`verify_batch` raises `BillionVerify::ValidationError` for more than 50 addresses without sending a request; use a file upload for larger lists.

## Verify a file

```ruby
job = client.upload_file("emails.csv", email_column: "email", preserve_original: true)
# Also accepts an open IO: client.upload_file(io, filename: "emails.csv")

status = client.wait_for_file_job(job.task_id, poll_interval: 5, max_wait: 600)
status.status           # => "completed"
status.deliverability_buckets.strict_deliverable

# Or check by hand; timeout (0-300 seconds) makes the call wait for the job (long polling).
client.get_file_job_status(job.task_id, timeout: 60)

# The result CSV, optionally only some statuses (filters are combined with OR).
csv = client.download_file_results(job.task_id, valid: true, catchall: true)
client.download_file_results(job.task_id, output_path: "results.csv")

# A paused job continues with:
client.resume_job(job.task_id)
```

Result files are served from a pre-signed storage URL. The client follows that redirect itself and does not send your API key to the storage host.

## Credits

```ruby
client.get_credits.credits_balance # => 9500
```

## Webhooks

```ruby
webhook = client.create_webhook("https://your-app.com/hooks/billionverify", ["file.completed", "file.failed"])
webhook.secret   # returned only now, store it

client.list_webhooks.map(&:url)
client.delete_webhook(webhook.id)
```

Verify every delivery before you trust it. The signature is an HMAC-SHA256 of `"<timestamp>.<raw body>"`, sent as `X-Webhook-Signature: sha256=<hex>`, with the time in `X-Webhook-Timestamp`:

```ruby
# Rails controller, for example
ok = BillionVerify.verify_webhook_signature(
  payload: request.raw_post,
  signature: request.headers["X-Webhook-Signature"],
  timestamp: request.headers["X-Webhook-Timestamp"],
  secret: ENV.fetch("BILLIONVERIFY_WEBHOOK_SECRET"),
  tolerance: 300 # seconds; older or future timestamps are rejected. 0 turns the check off.
)
head :unauthorized unless ok
```

## Domain search

Give a domain, get the emails published on its site, each one verified. It runs asynchronously and costs 5 credits per returned email; `max_emails` (1-200) caps the bill.

```ruby
search = client.create_domain_search("example.com", max_emails: 20, include_role_based: false, max_pages: 100)
done = client.wait_for_domain_search(search.search_id)
done.result.emails.each { |e| puts e.email }

# A CSV of domains
batch = client.create_domain_search_batch("domains.csv", max_emails: 10, column_map: { domain: "Company Website" })
client.get_domain_search_batch(batch.batch_id).progress.processed
client.list_domain_search_batches(limit: 20, status: "completed").items
csv = client.download_domain_search_batch_results(batch.batch_id) # 409 until the batch has finished
```

## Health

```ruby
client.health_check.status # => "ok"  (no API key needed)
```

## Errors

Every error is a `BillionVerify::Error` with `code`, `status_code`, `details` and `request_id`.

| Class | When |
| --- | --- |
| `ValidationError` | HTTP 400, or invalid arguments caught before the request |
| `AuthenticationError` | HTTP 401, or no API key |
| `InsufficientCreditsError` | HTTP 402 |
| `NotFoundError` | HTTP 404 |
| `RateLimitError` | HTTP 429 after the retries; has `retry_after` (seconds) |
| `TimeoutError` | The request or a `wait_for_*` helper ran out of time |
| `NetworkError` | The connection failed |
| `BillionVerify::Error` | Anything else (for example 409 or 500) |

```ruby
begin
  client.verify("user@example.com")
rescue BillionVerify::RateLimitError => e
  sleep e.retry_after
rescue BillionVerify::InsufficientCreditsError
  # top up
rescue BillionVerify::Error => e
  warn "#{e.status_code} #{e.code}: #{e.message}"
end
```

Responses with status 429, 500, 502 and 503 are retried (up to `retries` attempts in total), waiting `Retry-After` seconds when the server sends it and `2 ** attempt` seconds otherwise.

## Development

```sh
bundle install
bundle exec rake test
```

The tests use WebMock and a local fake server; they never call the real API.

## Releasing

1. Update `lib/billionverify/version.rb` and `CHANGELOG.md`, run `bundle exec rake test`, commit.
2. Tag and push: `git tag v1.0.0 && git push origin main v1.0.0`. The `Release` workflow checks that the tag matches the version, runs the tests and pushes the gem to RubyGems with the `RUBYGEMS_API_KEY` repository secret (it does nothing if that version is already on RubyGems, for example after a release by hand).
3. To release by hand instead: `gem build billionverify.gemspec && gem push billionverify-1.0.0.gem`.

## License

MIT
