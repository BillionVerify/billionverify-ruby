# frozen_string_literal: true

require "test_helper"

class ClientTest < Minitest::Test
  def test_requires_api_key
    assert_raises(BillionVerify::AuthenticationError) { BillionVerify::Client.new(api_key: "") }
    assert_raises(BillionVerify::AuthenticationError) { BillionVerify::Client.new(api_key: nil) }
  end

  def test_base_url_is_normalised
    assert_equal "https://api.billionverify.com", BillionVerify::Client.new(api_key: "k", base_url: "https://api.billionverify.com/v1/").base_url
    assert_equal "https://example.test", BillionVerify::Client.new(api_key: "k", base_url: "https://example.test//").base_url
  end

  def test_inspect_hides_the_api_key
    refute_includes client.inspect, "test-key"
  end

  def test_verify_sends_headers_and_only_given_options
    stub = stub_request(:post, "#{BASE}/v1/verify/single")
           .with(headers: { "BV-API-KEY" => "test-key", "Content-Type" => "application/json",
                            "User-Agent" => "billionverify-ruby/#{BillionVerify::VERSION}" },
                 body: { email: "user@example.com" }.to_json)
           .to_return(json_response({ email: "user@example.com", status: "valid", score: 0.95, is_deliverable: true,
                                      risk_reasons: ["x"], domain_reputation: { is_listed: false } }))
    result = client.verify("user@example.com")
    assert_requested stub
    assert_equal "valid", result.status
    assert_equal 0.95, result.score
    assert result.is_deliverable?
    assert_equal false, result.domain_reputation.is_listed
    assert_equal ["x"], result.risk_reasons
    assert_nil result.not_a_field
    assert_equal "valid", result[:status]
  end

  def test_verify_sends_all_options
    stub = stub_request(:post, "#{BASE}/v1/verify/single")
           .with(body: { email: "a@b.co", check_smtp: false, force_refresh: true, include_domain_reputation: true }.to_json)
           .to_return(json_response({ email: "a@b.co", status: "unknown" }))
    client.verify("a@b.co", check_smtp: false, force_refresh: true, include_domain_reputation: true)
    assert_requested stub
  end

  def test_verify_batch
    emails = %w[a@b.co c@d.co]
    stub_request(:post, "#{BASE}/v1/verify/bulk").with(body: { emails: emails }.to_json)
      .to_return(json_response({ results: [{ email: "a@b.co", status: "valid" }, { email: "c@d.co", status: "invalid" }],
                                 total_emails: 2, deliverability_buckets: { strict_deliverable: 1 } }))
    result = client.verify_batch(emails)
    assert_equal 2, result.total_emails
    assert_equal "invalid", result.results.last.status
    assert_equal 1, result.deliverability_buckets.strict_deliverable
  end

  def test_verify_batch_rejects_more_than_fifty_without_a_request
    err = assert_raises(BillionVerify::ValidationError) { client.verify_batch(Array.new(51) { |i| "u#{i}@x.co" }) }
    assert_match(/50/, err.message)
    assert_not_requested :post, "#{BASE}/v1/verify/bulk"
    assert_raises(BillionVerify::ValidationError) { client.verify_batch("a@b.co") }
  end

  def test_check_disposable_post_and_query
    stub_request(:post, "#{BASE}/v1/verify/disposable").with(body: { email: "x@mailinator.com" }.to_json)
      .to_return(json_response({ email: "x@mailinator.com", is_disposable: true }))
    stub_request(:get, "#{BASE}/v1/verify/disposable?email=x%2Bt%40mailinator.com")
      .to_return(json_response({ email: "x+t@mailinator.com", is_disposable: true }))
    assert client.check_disposable("x@mailinator.com").is_disposable
    assert client.check_disposable_via_query("x+t@mailinator.com").is_disposable
  end

  def with_server(**opts)
    server = FakeServer.new(**opts)
    yield server, BillionVerify::Client.new(api_key: "test-key", base_url: server.url)
  ensure
    server&.stop
  end

  def test_upload_file_sends_multipart_fields
    file = Tempfile.new(["emails", ".csv"])
    file.write("email\na@b.co\n")
    file.close
    with_server(body: envelope({ task_id: "job-1", status: "pending" })) do |server, c|
      result = c.upload_file(file.path, check_smtp: false, email_column: "email", preserve_original: true)
      assert_equal "job-1", result.task_id
      req = server.requests.last
      assert_equal "POST", req.method
      assert_equal "/v1/verify/file", req.path
      assert_equal "test-key", req.headers["bv-api-key"]
      assert_match(%r{\Amultipart/form-data; boundary=}, req.headers["content-type"])
      parts = multipart_parts(req.headers["content-type"], req.body)
      assert_equal "false", parts["check_smtp"][:value]
      assert_equal "email", parts["email_column"][:value]
      assert_equal "true", parts["preserve_original"][:value]
      assert_match(/filename="#{File.basename(file.path)}"/, parts["file"][:head])
      assert_match(%r{Content-Type: text/csv}i, parts["file"][:head])
      assert_equal "email\na@b.co\n", parts["file"][:value]
    end
  ensure
    file&.unlink
  end

  def test_upload_file_from_io_and_missing_path
    with_server(body: envelope({ task_id: "j" })) do |server, c|
      assert_equal "j", c.upload_file(StringIO.new("a@b.co\n"), filename: "list.txt").task_id
      assert_match(/filename="list.txt"/, server.requests.last.body)
    end
    assert_raises(BillionVerify::ValidationError) { client.upload_file("/nonexistent/file.csv") }
  end

  def test_get_file_job_status_and_long_polling
    stub_request(:get, "#{BASE}/v1/verify/file/job-1").to_return(json_response({ task_id: "job-1", status: "running" }))
    stub_request(:get, "#{BASE}/v1/verify/file/job-1?timeout=60").to_return(json_response({ task_id: "job-1", status: "completed" }))
    assert_equal "running", client.get_file_job_status("job-1").status
    assert_equal "completed", client.get_file_job_status("job-1", timeout: 60).status
    assert_raises(BillionVerify::ValidationError) { client.get_file_job_status("job-1", timeout: 301) }
    assert_raises(BillionVerify::ValidationError) { client.get_file_job_status("job-1", timeout: -1) }
  end

  def test_path_ids_are_escaped
    stub = stub_request(:get, "#{BASE}/v1/verify/file/a%2Fb%20c").to_return(json_response({ status: "running" }))
    client.get_file_job_status("a/b c")
    assert_requested stub
  end

  def test_wait_for_file_job_polls_until_done
    stub_request(:get, "#{BASE}/v1/verify/file/job-1").to_return(
      json_response({ status: "running" }), json_response({ status: "merging" }),
      json_response({ status: "completed_with_warning" })
    )
    c = client
    assert_equal "completed_with_warning", c.wait_for_file_job("job-1", poll_interval: 7).status
    assert_equal [7, 7], @sleeps
  end

  def test_wait_for_file_job_times_out
    stub_request(:get, "#{BASE}/v1/verify/file/job-1").to_return(json_response({ status: "running" }))
    now = 0.0
    c = BillionVerify::Client.new(api_key: "k", sleeper: ->(s) { now += s }, clock: -> { now })
    assert_raises(BillionVerify::TimeoutError) { c.wait_for_file_job("job-1", poll_interval: 5, max_wait: 12) }
  end

  def test_download_file_results_with_filters
    stub = stub_request(:get, "#{BASE}/v1/verify/file/job-1/results?valid=true&risky=true")
           .with(headers: { "BV-API-KEY" => "test-key" })
           .to_return(status: 200, body: "email,status\na@b.co,valid\n", headers: { "Content-Type" => "text/csv" })
    csv = client.download_file_results("job-1", valid: true, risky: true, invalid: false)
    assert_requested stub
    assert_equal "email,status\na@b.co,valid\n", csv
    assert_raises(BillionVerify::ValidationError) { client.download_file_results("job-1", bogus: true) }
  end

  def test_download_file_results_to_a_path
    stub_request(:get, "#{BASE}/v1/verify/file/job-1/results").to_return(status: 200, body: "csv")
    Tempfile.create("out") do |f|
      assert_equal f.path, client.download_file_results("job-1", output_path: f.path)
      assert_equal "csv", File.read(f.path)
    end
  end

  def test_download_does_not_send_the_api_key_to_another_host
    stub_request(:get, "#{BASE}/v1/verify/file/job-1/results")
      .to_return(status: 307, headers: { "Location" => "https://storage.example.net/r/job-1.csv?sig=abc" })
    stub_request(:get, "https://storage.example.net/r/job-1.csv?sig=abc").to_return(status: 200, body: "csv-data")
    assert_equal "csv-data", client.download_file_results("job-1")
    assert_requested(:get, "https://storage.example.net/r/job-1.csv?sig=abc") { |req| !req.headers.keys.map(&:downcase).include?("bv-api-key") }
  end

  def test_download_keeps_the_api_key_on_a_same_host_redirect
    stub_request(:get, "#{BASE}/v1/verify/file/job-1/results").to_return(status: 307, headers: { "Location" => "/v1/files/x" })
    stub = stub_request(:get, "#{BASE}/v1/files/x").with(headers: { "BV-API-KEY" => "test-key" }).to_return(status: 200, body: "ok")
    assert_equal "ok", client.download_file_results("job-1")
    assert_requested stub
  end

  def test_download_gives_up_after_too_many_redirects
    stub_request(:get, "#{BASE}/v1/verify/file/job-1/results").to_return(status: 307, headers: { "Location" => "/v1/verify/file/job-1/results" })
    assert_raises(BillionVerify::Error) { client.download_file_results("job-1") }
  end

  def test_resume_job
    stub = stub_request(:post, "#{BASE}/v1/jobs/job-1/resume").to_return(json_response({ task_id: "job-1", status: "processing" }))
    assert_equal "processing", client.resume_job("job-1").status
    assert_requested stub
  end

  def test_get_credits
    stub_request(:get, "#{BASE}/v1/credits").to_return(json_response({ credits_balance: 9500, account_id: "abc" }))
    assert_equal 9500, client.get_credits.credits_balance
  end

  def test_webhooks
    stub_request(:post, "#{BASE}/v1/webhooks").with(body: { url: "https://x.test/h", events: ["file.completed"] }.to_json)
      .to_return(json_response({ id: "w1", secret: "s3cret", is_active: true }))
    stub_request(:get, "#{BASE}/v1/webhooks")
      .to_return(json_response({ webhooks: [{ id: "w1", url: "https://x.test/h", last_delivery_status: "success" }], total: 1 }))
    stub_request(:delete, "#{BASE}/v1/webhooks/w1").to_return(json_response({ message: "Webhook deleted successfully", webhook_id: "w1" }))
    created = client.create_webhook("https://x.test/h", ["file.completed"])
    assert_equal "s3cret", created.secret
    list = client.list_webhooks
    assert_equal 1, list.length
    assert_equal "success", list.first.last_delivery_status
    assert_equal "w1", client.delete_webhook("w1").webhook_id
  end

  def test_create_domain_search
    stub_request(:post, "#{BASE}/v1/domain/search")
      .with(body: { domain: "example.com", max_emails: 10, include_role_based: false, max_pages: 50 }.to_json)
      .to_return(json_response({ search_id: "s1", status: "queued", credits_reserved: 50 }, status: 202))
    result = client.create_domain_search("example.com", max_emails: 10, include_role_based: false, max_pages: 50)
    assert_equal "s1", result.search_id
    assert_raises(BillionVerify::ValidationError) { client.create_domain_search("example.com", max_emails: 0) }
    assert_raises(BillionVerify::ValidationError) { client.create_domain_search("example.com", max_emails: 201) }
  end

  def test_get_and_wait_for_domain_search
    stub_request(:get, "#{BASE}/v1/domain/search/s1").to_return(
      json_response({ search_id: "s1", status: "queued" }),
      json_response({ search_id: "s1", status: "completed", result: { emails: [{ email: "a@example.com" }] } })
    )
    done = client.wait_for_domain_search("s1")
    assert_equal "a@example.com", done.result.emails.first.email
    assert_equal [5], @sleeps
  end

  def test_domain_search_batch_lifecycle
    file = StringIO.new("domain\nexample.com\n")
    with_server(status: 202, body: envelope({ batch_id: "b1", status: "queued" })) do |server, c|
      created = c.create_domain_search_batch(file, filename: "d.csv", max_emails: 5, include_role_based: false,
                                                   max_pages: 20, column_map: { domain: "Company Website" })
      assert_equal "b1", created.batch_id
      req = server.requests.last
      assert_equal "/v1/domain/search/batch", req.path
      parts = multipart_parts(req.headers["content-type"], req.body)
      assert_equal "5", parts["max_emails"][:value]
      assert_equal "false", parts["include_role_based"][:value]
      assert_equal "20", parts["max_pages"][:value]
      assert_equal({ "domain" => "Company Website" }, JSON.parse(parts["column_map"][:value]))
      assert_equal "domain\nexample.com\n", parts["file"][:value]
    end

    stub_request(:get, "#{BASE}/v1/domain/search/batch?limit=5&status=completed&cursor=c1")
      .to_return(json_response({ items: [{ batch_id: "b1" }], has_more: true, next_cursor: "c2" }))
    page = client.list_domain_search_batches(limit: 5, status: "completed", cursor: "c1")
    assert page.has_more
    assert_equal "c2", page.next_cursor

    stub_request(:get, "#{BASE}/v1/domain/search/batch/b1").to_return(json_response({ batch_id: "b1", progress: { processed: 3 } }))
    assert_equal 3, client.get_domain_search_batch("b1").progress.processed

    stub_request(:get, "#{BASE}/v1/domain/search/batch/b1/results").to_return(status: 200, body: "row_no,domain\n1,example.com\n")
    assert_equal "row_no,domain\n1,example.com\n", client.download_domain_search_batch_results("b1")
  end

  def test_batch_results_409_is_an_error_with_status
    stub_request(:get, "#{BASE}/v1/domain/search/batch/b1/results").to_return(error_response(409, "NOT_READY", "Results are not ready yet"))
    err = assert_raises(BillionVerify::Error) { client.download_domain_search_batch_results("b1") }
    assert_equal 409, err.status_code
    assert_equal "NOT_READY", err.code
  end

  def test_health_check_needs_no_key_and_has_no_envelope
    stub_request(:get, "#{BASE}/health").to_return(status: 200, body: '{"status":"ok","time":1705319400}')
    health = client.health_check
    assert_equal "ok", health.status
    assert_equal 1_705_319_400, health.time
    assert_requested(:get, "#{BASE}/health") { |req| !req.headers.keys.map(&:downcase).include?("bv-api-key") }
  end

  def test_error_mapping
    {
      400 => [BillionVerify::ValidationError, "INVALID_REQUEST"],
      401 => [BillionVerify::AuthenticationError, "INVALID_API_KEY"],
      402 => [BillionVerify::InsufficientCreditsError, "INSUFFICIENT_CREDITS"],
      404 => [BillionVerify::NotFoundError, "JOB_NOT_FOUND"]
    }.each do |status, (klass, code)|
      stub_request(:get, "#{BASE}/v1/credits").to_return(error_response(status, code, "boom #{status}", headers: { "X-Request-ID" => "req-1" }))
      err = assert_raises(klass) { client.get_credits }
      assert_equal status, err.status_code
      assert_equal code, err.code
      assert_equal "boom #{status}", err.message.sub(/\A#{code}: /, "")
      assert_equal "req-1", err.request_id
      assert_kind_of BillionVerify::Error, err
    end
  end

  def test_error_without_a_json_body
    stub_request(:get, "#{BASE}/v1/credits").to_return(status: 418, body: "teapot")
    err = assert_raises(BillionVerify::Error) { client.get_credits }
    assert_equal 418, err.status_code
    assert_equal "UNKNOWN_ERROR", err.code
  end

  def test_retries_429_with_retry_after
    stub_request(:get, "#{BASE}/v1/credits").to_return(
      error_response(429, "RATE_LIMIT_EXCEEDED", "slow down", headers: { "Retry-After" => "7" }),
      json_response({ credits_balance: 1 })
    )
    assert_equal 1, client.get_credits.credits_balance
    assert_equal [7], @sleeps
  end

  def test_retries_5xx_with_exponential_backoff
    stub_request(:get, "#{BASE}/v1/credits").to_return(error_response(503, "X", "down"), error_response(502, "X", "down"),
                                                       json_response({ credits_balance: 2 }))
    assert_equal 2, client.get_credits.credits_balance
    assert_equal [2, 4], @sleeps
  end

  def test_gives_up_after_the_configured_attempts
    stub = stub_request(:get, "#{BASE}/v1/credits").to_return(error_response(429, "RATE_LIMIT_EXCEEDED", "slow", headers: { "Retry-After" => "3" }))
    err = assert_raises(BillionVerify::RateLimitError) { client(retries: 3).get_credits }
    assert_equal 3, err.retry_after
    assert_equal 429, err.status_code
    assert_requested stub, times: 3
    assert_equal [3, 3], @sleeps
  end

  def test_server_error_after_retries_raises_the_base_error
    stub_request(:get, "#{BASE}/v1/credits").to_return(error_response(500, "INTERNAL", "oops"))
    err = assert_raises(BillionVerify::Error) { client(retries: 2).get_credits }
    assert_equal 500, err.status_code
    assert_equal "INTERNAL", err.code
  end

  def test_client_errors_are_not_retried
    stub = stub_request(:get, "#{BASE}/v1/credits").to_return(error_response(401, "INVALID_API_KEY", "bad key"))
    assert_raises(BillionVerify::AuthenticationError) { client.get_credits }
    assert_requested stub, times: 1
  end

  def test_timeout_and_network_errors
    stub_request(:get, "#{BASE}/v1/credits").to_timeout
    assert_raises(BillionVerify::TimeoutError) { client.get_credits }
    stub_request(:get, "#{BASE}/v1/credits").to_raise(Errno::ECONNREFUSED)
    err = assert_raises(BillionVerify::NetworkError) { client.get_credits }
    assert_equal "NETWORK_ERROR", err.code
    assert_equal 0, err.status_code
  end

  def test_empty_and_invalid_success_bodies
    stub_request(:delete, "#{BASE}/v1/webhooks/w1").to_return(status: 204)
    assert_nil client.delete_webhook("w1")
    stub_request(:get, "#{BASE}/v1/credits").to_return(status: 200, body: "<html>")
    assert_equal "INVALID_RESPONSE", assert_raises(BillionVerify::Error) { client.get_credits }.code
  end
end
