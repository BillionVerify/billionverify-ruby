# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "billionverify"
require "minitest/autorun"
require "webmock/minitest"
require "json"
require "stringio"
require "tempfile"
require "socket"

WebMock.disable_net_connect!(allow_localhost: true)

module TestHelper
  BASE = "https://api.billionverify.com"

  def envelope(data)
    JSON.generate({ success: true, code: "0", message: "Success", data: data })
  end

  def json_response(data, status: 200, headers: {})
    { status: status, body: envelope(data), headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  def error_response(status, code, message, headers: {})
    body = JSON.generate({ success: false, code: status.to_s, message: message, error: { code: code, message: message } })
    { status: status, body: body, headers: { "Content-Type" => "application/json" }.merge(headers) }
  end

  def client(**opts)
    @sleeps ||= []
    BillionVerify::Client.new(api_key: "test-key", sleeper: ->(s) { @sleeps << s }, **opts)
  end

  # Splits a multipart/form-data body into { "field" => { head:, value: } }.
  def multipart_parts(content_type, body)
    boundary = content_type[/boundary=(.+)\z/, 1]
    body.split("--#{boundary}").map { |p| p.sub(/\A\r\n/, "").sub(/\r\n\z/, "") }.reject { |p| p.empty? || p == "--" }.to_h do |part|
      head, value = part.split("\r\n\r\n", 2)
      [head[/name="([^"]+)"/, 1], { head: head, value: value.to_s }]
    end
  end
end

# A tiny HTTP server on localhost that records requests, for the cases WebMock cannot see
# (streamed multipart bodies).
class FakeServer
  Recorded = Struct.new(:method, :path, :headers, :body)
  attr_reader :requests

  def initialize(status: 200, body: "{}")
    @status = status
    @body = body
    @requests = []
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { loop { handle(@server.accept) } }
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}"
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def handle(sock)
    line = sock.gets or return sock.close
    method, path, = line.split
    headers = {}
    while (l = sock.gets) && l != "\r\n"
      k, v = l.chomp.split(": ", 2)
      headers[k.downcase] = v
    end
    data = if headers["transfer-encoding"].to_s.include?("chunked")
             read_chunked(sock)
           else
             sock.read(headers["content-length"].to_i).to_s
           end
    @requests << Recorded.new(method, path, headers, data)
    sock.write("HTTP/1.1 #{@status} X\r\nContent-Type: application/json\r\nContent-Length: #{@body.bytesize}\r\nConnection: close\r\n\r\n#{@body}")
    sock.close
  end

  def read_chunked(sock)
    out = +""
    loop do
      size = sock.gets.to_i(16)
      break if size.zero?

      out << sock.read(size)
      sock.read(2)
    end
    sock.gets
    out
  end
end

class Minitest::Test
  include TestHelper
end
