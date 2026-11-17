# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module BillionVerify
  # The BillionVerify API client.
  #
  #   client = BillionVerify::Client.new(api_key: ENV.fetch("BILLIONVERIFY_API_KEY"))
  #   client.verify("user@example.com").status # => "valid"
  #
  # Every method returns the +data+ of the API's response as a
  # BillionVerify::Object (or an Array of them) and raises a subclass of
  # BillionVerify::Error on failure.
  class Client
    DEFAULT_BASE_URL = "https://api.billionverify.com"
    DEFAULT_TIMEOUT = 30
    DEFAULT_RETRIES = 3
    MAX_BATCH_EMAILS = 50
    RETRYABLE_STATUSES = [429, 500, 502, 503].freeze
    FILE_JOB_DONE = %w[completed completed_with_warning failed cancelled paused].freeze
    DOMAIN_SEARCH_DONE = %w[completed completed_with_warning failed].freeze
    RESULT_FILTERS = %i[valid invalid catchall role unknown disposable risky].freeze
    MAX_REDIRECTS = 5

    attr_reader :base_url, :timeout, :retries

    # @param api_key [String] your BillionVerify API key
    # @param base_url [String] defaults to https://api.billionverify.com (a trailing +/v1+ is accepted)
    # @param timeout [Numeric] seconds per request, default 30
    # @param retries [Integer] total attempts for 429, 500, 502 and 503 responses, default 3
    # @param sleeper [#call] called with the seconds to wait between attempts; replace it in tests
    # @param clock [#call] returns a monotonic time in seconds; replace it in tests
    def initialize(api_key:, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT, retries: DEFAULT_RETRIES,
                   sleeper: ->(seconds) { sleep(seconds) },
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      raise AuthenticationError, "API key is required" if api_key.nil? || api_key.to_s.strip.empty?

      @api_key = api_key.to_s
      @base_url = base_url.to_s.sub(%r{/+\z}, "").sub(%r{/v1\z}, "")
      @timeout = timeout
      @retries = [retries.to_i, 1].max
      @sleeper = sleeper
      @clock = clock
    end

    # Does not print the API key.
    def inspect
      "#<#{self.class} base_url=#{@base_url.inspect}>"
    end

    # ----- Verification -------------------------------------------------

    # Verifies one address. Options that are +nil+ are not sent, so the server default applies.
    def verify(email, check_smtp: nil, force_refresh: nil, include_domain_reputation: nil)
      body = compact(email: email, check_smtp: check_smtp, force_refresh: force_refresh,
                     include_domain_reputation: include_domain_reputation)
      data(post_json("/v1/verify/single", body))
    end

    # Verifies up to 50 addresses in one synchronous request. Use #upload_file for more.
    def verify_batch(emails, check_smtp: nil, force_refresh: nil, include_domain_reputation: nil)
      raise ValidationError, "emails must be an Array" unless emails.is_a?(::Array)
      if emails.length > MAX_BATCH_EMAILS
        raise ValidationError, "Maximum #{MAX_BATCH_EMAILS} emails per batch request. For larger lists, use upload_file."
      end

      body = compact(emails: emails, check_smtp: check_smtp, force_refresh: force_refresh,
                     include_domain_reputation: include_domain_reputation)
      data(post_json("/v1/verify/bulk", body))
    end

    # Free lookup against the disposable-domain table (POST).
    def check_disposable(email)
      data(post_json("/v1/verify/disposable", { email: email }))
    end

    # Same as #check_disposable, with the address in the query string (GET).
    def check_disposable_via_query(email)
      data(call(:get, "/v1/verify/disposable", query: { email: email }))
    end

    # ----- File verification --------------------------------------------

    # Uploads a CSV, XLSX or TXT file of addresses for asynchronous verification.
    #
    # @param file [String, Pathname, IO] a path or an open IO
    # @param filename [String] defaults to the path's basename
    def upload_file(file, filename: nil, check_smtp: nil, email_column: nil, preserve_original: nil)
      fields = compact(check_smtp: check_smtp, email_column: email_column, preserve_original: preserve_original)
      data(call(:post, "/v1/verify/file", multipart: build_upload(file, filename, "file", fields)))
    end

    # Status of a file job. +timeout+ (0-300 seconds) turns on long polling.
    def get_file_job_status(job_id, timeout: nil)
      query = {}
      unless timeout.nil?
        raise ValidationError, "timeout must be between 0 and 300 seconds" unless (0..300).cover?(timeout)

        query[:timeout] = timeout
      end
      request_timeout = timeout.to_i.positive? ? timeout + 10 : nil
      data(call(:get, "/v1/verify/file/#{path_id(job_id)}", query: query, timeout: request_timeout))
    end

    # Polls until the job leaves the running states (completed, completed_with_warning,
    # failed, cancelled or paused). Raises TimeoutError after +max_wait+ seconds.
    def wait_for_file_job(job_id, poll_interval: 5, max_wait: 600)
      wait_for(max_wait, "File job #{job_id}") do
        status = get_file_job_status(job_id)
        [FILE_JOB_DONE.include?(status.status), status, poll_interval]
      end
    end

    # Downloads the result CSV of a completed job and returns it as a String. With
    # +output_path+ the CSV is written there and the path is returned. Filters
    # (valid:, invalid:, catchall:, role:, unknown:, disposable:, risky:) are combined with OR.
    def download_file_results(job_id, output_path: nil, **filters)
      unknown = filters.keys - RESULT_FILTERS
      raise ValidationError, "unknown filter: #{unknown.join(", ")}" unless unknown.empty?

      query = filters.select { |_, v| v }.transform_values { "true" }
      body = download("/v1/verify/file/#{path_id(job_id)}/results", query)
      return body unless output_path

      File.binwrite(output_path, body)
      output_path
    end

    # Resumes a paused file job. Returns the job status.
    def resume_job(job_id)
      data(call(:post, "/v1/jobs/#{path_id(job_id)}/resume"))
    end

    # ----- Account ------------------------------------------------------

    def get_credits
      data(call(:get, "/v1/credits"))
    end

    # ----- Webhooks -----------------------------------------------------

    # Creates a webhook. +events+ are "file.completed" and "file.failed"; the URL must be https.
    # The returned object carries the signing +secret+ once, so store it.
    def create_webhook(url, events)
      data(post_json("/v1/webhooks", { url: url, events: events }))
    end

    # @return [Array<BillionVerify::Object>]
    def list_webhooks
      result = data(call(:get, "/v1/webhooks"))
      result.nil? ? [] : Array(result.webhooks)
    end

    def delete_webhook(webhook_id)
      data(call(:delete, "/v1/webhooks/#{path_id(webhook_id)}"))
    end

    # See WebhookSignature.valid?.
    def verify_webhook_signature(**args)
      WebhookSignature.valid?(**args)
    end

    # ----- Domain search (email finder) ---------------------------------

    # Starts a domain search. +max_emails+ (1-200) caps the bill: 5 credits per returned email.
    def create_domain_search(domain, max_emails:, include_role_based: nil, max_pages: nil)
      check_max_emails(max_emails)
      body = compact(domain: domain, max_emails: max_emails, include_role_based: include_role_based,
                     max_pages: max_pages)
      data(post_json("/v1/domain/search", body))
    end

    def get_domain_search(search_id)
      data(call(:get, "/v1/domain/search/#{path_id(search_id)}"))
    end

    # Polls until the search is completed, completed_with_warning or failed.
    def wait_for_domain_search(search_id, poll_interval: 5, max_wait: 600)
      wait_for(max_wait, "Domain search #{search_id}") do
        search = get_domain_search(search_id)
        [DOMAIN_SEARCH_DONE.include?(search.status), search, poll_interval]
      end
    end

    # Uploads a CSV of domains. +column_map+ may be a Hash or a JSON string.
    def create_domain_search_batch(file, filename: nil, max_emails: nil, include_role_based: nil, max_pages: nil,
                                   column_map: nil)
      check_max_emails(max_emails) unless max_emails.nil?
      column_map = JSON.generate(column_map) if column_map.is_a?(::Hash)
      fields = compact(max_emails: max_emails, include_role_based: include_role_based, max_pages: max_pages,
                       column_map: column_map)
      data(call(:post, "/v1/domain/search/batch", multipart: build_upload(file, filename, "file", fields)))
    end

    # One page of batches: an object with +items+, +has_more+ and +next_cursor+.
    def list_domain_search_batches(limit: nil, status: nil, cursor: nil)
      data(call(:get, "/v1/domain/search/batch", query: compact(limit: limit, status: status, cursor: cursor)))
    end

    def get_domain_search_batch(batch_id)
      data(call(:get, "/v1/domain/search/batch/#{path_id(batch_id)}"))
    end

    # The result CSV (one row per returned email) as a String. Raises Error with status 409 until the batch ended.
    def download_domain_search_batch_results(batch_id, output_path: nil)
      body = download("/v1/domain/search/batch/#{path_id(batch_id)}/results", {})
      return body unless output_path

      File.binwrite(output_path, body)
      output_path
    end

    # ----- Health -------------------------------------------------------

    # No authentication needed. Returns an object with +status+ and +time+.
    def health_check
      body = call(:get, "/health", auth: false)
      body.is_a?(::Hash) ? Object.new(body) : body
    end

    private

    Response = Struct.new(:status, :headers, :body)

    def post_json(path, body)
      call(:post, path, json: body)
    end

    # Runs a request with retries and returns the parsed JSON body.
    def call(method, path, query: nil, json: nil, multipart: nil, auth: true, timeout: nil)
      response = with_retries do
        perform(method, build_uri(path, query), json: json, multipart: multipart, auth: auth, timeout: timeout)
      end
      parse_body(response)
    end

    # GET that returns the raw body and follows redirects without forwarding the API key
    # to another host (result files are served from a pre-signed storage URL).
    def download(path, query)
      uri = build_uri(path, query)
      auth = true
      (MAX_REDIRECTS + 1).times do
        response = with_retries { perform(:get, uri, auth: auth) }
        return response.body.to_s.dup.force_encoding(Encoding::UTF_8) if response.status.between?(200, 299)

        location = response.headers["location"]
        if [301, 302, 303, 307, 308].include?(response.status) && location
          target = URI.join(uri.to_s, location)
          auth = auth && same_origin?(target, uri)
          uri = target
          next
        end
        raise_for(response)
      end
      raise Error.new("Too many redirects", code: "TOO_MANY_REDIRECTS")
    end

    def with_retries
      attempt = 1
      loop do
        response = yield
        return response unless RETRYABLE_STATUSES.include?(response.status) && attempt < @retries

        retry_after = response.headers["retry-after"].to_i
        wait = response.status == 429 && retry_after.positive? ? retry_after : 2**attempt
        @sleeper.call(wait)
        attempt += 1
      end
    end

    def perform(method, uri, json: nil, multipart: nil, auth: true, timeout: nil)
      request = build_request(method, uri, json, multipart, auth)
      seconds = timeout || @timeout
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = http.write_timeout = seconds
      begin
        net = http.start { |conn| conn.request(request) }
      ensure
        multipart&.dig(:cleanup)&.call
      end
      Response.new(net.code.to_i, net.each_header.to_h { |k, v| [k.downcase, v] }, net.body)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout
      raise TimeoutError, "Request timed out after #{seconds}s"
    rescue SocketError, SystemCallError, OpenSSL::SSL::SSLError, EOFError, IOError => e
      raise NetworkError, "Network error: #{e.message}"
    end

    def build_request(method, uri, json, multipart, auth)
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
      request = klass.new(uri)
      request["User-Agent"] = "billionverify-ruby/#{VERSION}"
      request["Accept"] = "application/json"
      request["BV-API-KEY"] = @api_key if auth
      if json
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(json)
      elsif multipart
        request.set_form(multipart.fetch(:parts).call, "multipart/form-data")
      end
      request
    end

    def build_uri(path, query)
      uri = URI.parse("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(query) if query && !query.empty?
      uri
    end

    def same_origin?(a, b)
      a.scheme == b.scheme && a.host == b.host && a.port == b.port
    end

    def parse_body(response)
      raise_for(response) unless response.status.between?(200, 299)
      body = response.body.to_s
      return nil if response.status == 204 || body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError => e
      raise Error.new("Invalid JSON in response: #{e.message}", code: "INVALID_RESPONSE", status_code: response.status)
    end

    # Returns the envelope's +data+ wrapped, or the body itself when there is no envelope.
    def data(body)
      payload = body.is_a?(::Hash) && body.key?("data") ? body["data"] : body
      payload.is_a?(::Hash) ? Object.new(payload) : payload
    end

    def raise_for(response)
      info = begin
        parsed = JSON.parse(response.body.to_s)
        parsed.is_a?(::Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
      error = info["error"].is_a?(::Hash) ? info["error"] : {}
      message = error["message"] || info["message"] || "HTTP #{response.status}"
      common = { code: error["code"] || "UNKNOWN_ERROR", details: error["details"] || error["description"],
                 request_id: response.headers["x-request-id"] }
      case response.status
      when 400 then raise ValidationError.new(message, **common)
      when 401 then raise AuthenticationError.new(message, **common)
      when 402 then raise InsufficientCreditsError.new(message, **common)
      when 404 then raise NotFoundError.new(message, **common)
      when 429
        raise RateLimitError.new(message, retry_after: response.headers["retry-after"].to_i, **common)
      else
        raise Error.new(message, status_code: response.status, **common)
      end
    end

    def wait_for(max_wait, label)
      deadline = @clock.call + max_wait
      loop do
        done, value, interval = yield
        return value if done
        raise TimeoutError, "#{label} did not finish within #{max_wait}s" if @clock.call >= deadline

        @sleeper.call(interval)
      end
    end

    # Builds a multipart description whose parts are produced fresh for each attempt.
    def build_upload(file, filename, field, fields)
      raise ValidationError, "file is required" if file.nil?

      opened = nil
      path = file.respond_to?(:to_path) ? file.to_path : (file.is_a?(::String) ? file : nil)
      raise ValidationError, "File not found: #{path}" if path && !File.file?(path)

      name = filename || (path ? File.basename(path) : "upload.csv")
      parts = lambda do
        io = if path
               opened = File.open(path, "rb")
             else
               file.rewind if file.respond_to?(:rewind)
               file
             end
        [[field, io, { filename: name, content_type: content_type_for(name) }]] +
          fields.map { |key, value| [key.to_s, value.to_s] }
      end
      { parts: parts, cleanup: -> { opened&.close } }
    end

    def content_type_for(name)
      case File.extname(name).downcase
      when ".csv" then "text/csv"
      when ".txt" then "text/plain"
      when ".xlsx" then "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
      else "application/octet-stream"
      end
    end

    def check_max_emails(value)
      return if value.is_a?(::Integer) && (1..200).cover?(value)

      raise ValidationError, "max_emails must be an integer between 1 and 200"
    end

    def path_id(id)
      raise ValidationError, "id is required" if id.nil? || id.to_s.empty?

      URI.encode_www_form_component(id.to_s).gsub("+", "%20")
    end

    def compact(hash)
      hash.reject { |_, v| v.nil? }
    end
  end
end
