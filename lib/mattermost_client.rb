# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

JST_OFFSET = "+09:00"
PER_PAGE = 200

$verbose = false

def say(message)
  puts message if $verbose
end

class MattermostClient
  def initialize(base_url:, token:, verify_ssl: false)
    @base_uri = URI(base_url.end_with?("/") ? base_url : "#{base_url}/")
    @token = token
    @verify_ssl = verify_ssl
  end

  def get(path, query = nil)
    uri = @base_uri + path.sub(%r{\A/}, "")
    uri.query = URI.encode_www_form(query) if query && !query.empty?

    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"

    say "accessing... #{uri}"
    response = with_http(uri) { |http| http.request(request) }

    unless response.is_a?(Net::HTTPSuccess)
      raise "Mattermost API error #{response.code} #{response.message}: #{response.body}"
    end

    JSON.parse(response.body)
  end

  def post(path, body = {})
    uri = @base_uri + path.sub(%r{\A/}, "")

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = body.to_json

    say "posting... #{uri}"
    response = with_http(uri) { |http| http.request(request) }

    unless response.is_a?(Net::HTTPSuccess)
      raise "Mattermost API error #{response.code} #{response.message}: #{response.body}"
    end

    JSON.parse(response.body)
  end

  private

  def with_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.verify_mode = @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
    http.read_timeout = 60
    http.open_timeout = 10
    yield(http)
  end
end
