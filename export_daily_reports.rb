#!/usr/bin/env ruby
# frozen_string_literal: true

require "date"
require "fileutils"
require "json"
require "net/http"
require "optparse"
require "time"
require "uri"

JST_OFFSET = "+09:00"
DEFAULT_BASE_URL = "https://chat.neogenia.co.jp/"
DEFAULT_TEAM_NAME = "Neogenia"
DEFAULT_CHANNEL_NAME = "times"
DEFAULT_OUTPUT_DIR = "./times/"
PER_PAGE = 200

REPORT_PATTERNS = [
  /#+\s*(業務)?日報/,
  /#+\s*感じたこと/,
  /#+\s*所感/
].freeze

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

class ReportExporter
  def initialize(client:, base_url:, team_name:, channel_name:, username:, from_date:, to_date:, out_dir:, overwrite:)
    @client = client
    @base_url = base_url
    @team_name = team_name
    @channel_name = channel_name
    @username = username
    @from_date = from_date
    @to_date = to_date
    @out_dir = out_dir
    @overwrite = overwrite
  end

  def run
    team_id = fetch_team_id(@team_name)
    channel_id = fetch_channel_id(team_id, @channel_name)
    user_id = fetch_user_id(@username)

    start_ms = day_start_ms(@from_date)
    end_ms = day_end_ms(@to_date)

    puts "Fetching posts for #{@username} (#{@from_date} .. #{@to_date})..."
    root_posts = fetch_user_root_posts_in_range(channel_id, user_id, start_ms, end_ms)
    say("Found #{root_posts.size} root posts")

    daily_roots = root_posts.group_by { |post| created_on_jst(post.fetch("create_at")) }

    stats = { saved: 0, skipped_existing: 0, no_report: 0 }

    each_day(@from_date, @to_date) do |date|
      print "  #{date}... "

      file_path = report_file_path(@username, date)
      if File.exist?(file_path) && !@overwrite
        stats[:skipped_existing] += 1
        puts "skipped (exists)"
        next
      end

      roots_today = (daily_roots[date] || []).sort_by { |post| post.fetch("create_at") }
      report_post = extract_last_report_post(roots_today, date, user_id)

      if report_post
        write_report(@username, date, report_post, file_path)
        stats[:saved] += 1
        puts "saved"
      else
        stats[:no_report] += 1
        puts "no report"
      end
    end

    puts "saved=#{stats[:saved]} skipped_existing=#{stats[:skipped_existing]} no_report=#{stats[:no_report]}"
  end

  private

  def fetch_team_id(team_name)
    @client.get("/api/v4/teams/name/#{team_name}").fetch("id")
  end

  def fetch_channel_id(team_id, channel_name)
    @client.get("/api/v4/teams/#{team_id}/channels/name/#{channel_name}").fetch("id")
  end

  def fetch_user_id(username)
    @client.get("/api/v4/users/username/#{username}").fetch("id")
  end

  # チャンネル投稿を新しい順にページングし、指定ユーザーの root 投稿だけを収集する。
  # 指定期間より古い投稿が出た時点で早期終了する。
  def fetch_user_root_posts_in_range(channel_id, user_id, start_ms, end_ms)
    page = 0
    posts = []

    loop do
      say("  fetching channel posts page #{page}...")
      response = @client.get(
        "/api/v4/channels/#{channel_id}/posts",
        { "page" => page, "per_page" => PER_PAGE }
      )

      order = response.fetch("order")
      break if order.empty?

      chunk = order.map { |id| response.fetch("posts").fetch(id) }

      say "    get #{chunk.size} posts so far. #{Time.at chunk.last.fetch("create_at")/1000}"
      chunk.each do |post|
        ts = post.fetch("create_at")
        next if ts > end_ms
        next unless ts >= start_ms
        next unless post["root_id"].nil? || post["root_id"].empty?
        next unless post["user_id"] == user_id

        posts << post
      end

      # 投稿は新しい順に返されるため、このページの最古投稿が開始時刻より前なら打ち切り
      oldest_ts = chunk.map { |post| post.fetch("create_at") }.min || 0
      break if oldest_ts < start_ms

      page += 1
    end

    posts
  end

  def extract_last_report_post(root_posts, date, user_id)
    candidates = []

    root_posts.each do |root|
      thread = @client.get("/api/v4/posts/#{root.fetch("id")}/thread")
      entries = thread.fetch("order").map { |id| thread.fetch("posts").fetch(id) }
      entries.sort_by { |post| post.fetch("create_at") }.reverse_each do |post|
        next unless post["user_id"] == user_id
        next unless created_on_jst(post.fetch("create_at")) == date
        next unless report_post?(post)

        candidates << post
        break
      end
    end

    candidates.max_by { |post| post.fetch("create_at") }
  end

  def report_post?(post)
    message = post["message"].to_s
    REPORT_PATTERNS.any? { |pattern| pattern.match?(message) }
  end

  def report_file_path(username, date)
    user_dir = File.join(@out_dir, username)
    FileUtils.mkdir_p(user_dir)
    File.join(user_dir, "#{date.strftime("%Y-%m-%d")}.md")
  end

  def write_report(username, date, post, file_path)
    permalink = URI.join(@base_url, "pl/#{post.fetch("id")}").to_s
    body = <<~MD
      # Daily Report
      - Username: #{username}
      - Date: #{date.strftime("%Y-%m-%d")}
      - Source Post: #{permalink}
    MD

    File.open(file_path, "w") do |file|
      file.write(body)
      file.write("\n")
      file.write(post["message"])
    end
  end

  def day_start_ms(date)
    Time.new(date.year, date.month, date.day, 0, 0, 0, JST_OFFSET).to_i * 1000
  end

  def day_end_ms(date)
    Time.new(date.year, date.month, date.day, 23, 59, 59, JST_OFFSET).to_i * 1000 + 999
  end

  def created_on_jst(ms)
    Time.at(ms / 1000.0).getlocal(JST_OFFSET).to_date
  end

  def each_day(from_date, to_date)
    date = from_date
    while date <= to_date
      yield(date)
      date += 1
    end
  end
end

def parse_args(argv)
  options = {
    base_url: ENV.fetch("MATTERMOST_BASE_URL", DEFAULT_BASE_URL),
    team_name: ENV.fetch("MATTERMOST_TEAM", DEFAULT_TEAM_NAME),
    channel_name: ENV.fetch("MATTERMOST_CHANNEL", DEFAULT_CHANNEL_NAME),
    out_dir: DEFAULT_OUTPUT_DIR,
    overwrite: false,
    verify_ssl: false,
    verbose: false
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby bin/export_mattermost_reports.rb --member USERNAME --from 2026-04-01 --to 2026-04-22 [options]"

    opts.on("--member USERNAME", "Mattermost username") do |value|
      options[:member] = value.strip
    end

    opts.on("--from YYYY-MM-DD", "Start date in JST") do |value|
      options[:from] = Date.strptime(value, "%Y-%m-%d")
    end

    opts.on("--to YYYY-MM-DD", "End date in JST") do |value|
      options[:to] = Date.strptime(value, "%Y-%m-%d")
    end

    opts.on("--out DIR", "Output directory (default: current directory)") do |value|
      options[:out_dir] = value
    end

    opts.on("-w", "Overwrite existing files") do
      options[:overwrite] = true
    end

    opts.on("-k", "--no-verify-ssl", "Skip SSL certificate verification") do
      options[:verify_ssl] = false
    end

    opts.on("-v", "Verbose logs") do
      options[:verbose] = true
    end

    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit(0)
    end
  end

  parser.parse!(argv)

  required = %i[member from to]
  missing = required.select { |key| options[key].nil? || (options[key].respond_to?(:empty?) && options[key].empty?) }
  raise OptionParser::MissingArgument, missing.join(", ") unless missing.empty?

  raise ArgumentError, "--from must be <= --to" if options[:from] > options[:to]

  options
end

def main(argv)
  options = parse_args(argv)
  $verbose = options[:verbose]

  token = ENV["MATTERMOST_TOKEN"]
  raise "MATTERMOST_TOKEN is required" if token.to_s.strip.empty?

  client = MattermostClient.new(base_url: options[:base_url], token: token, verify_ssl: options[:verify_ssl])
  exporter = ReportExporter.new(
    client: client,
    base_url: options[:base_url],
    team_name: options[:team_name],
    channel_name: options[:channel_name],
    username: options[:member],
    from_date: options[:from],
    to_date: options[:to],
    out_dir: options[:out_dir],
    overwrite: options[:overwrite]
  )

  exporter.run
end

begin
  main(ARGV)
rescue StandardError => e
  warn "error: #{e.message}"
  warn e.backtrace
  exit(1)
end
