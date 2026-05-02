#!/usr/bin/env ruby
# frozen_string_literal: true
#
# export_work-rule_refrections.rb
#
# Mattermost の チーム改善（team）チャンネルから、#ワークルールMTG タグのついた
# 投稿を取得して Markdown ファイルとして保存するスクリプト。
#
# 【仕様】
#   - 対象チャンネル : team（デフォルト）
#   - ユーザー指定   : --member（省略時は全メンバーが対象）
#   - 期間指定       : --from / --to（JST、両端含む）
#   - 投稿判定       : 本文に #ワークルールMTG を含む
#   - 取得方式       : 検索APIを日付ウィンドウ（デフォルト60日）に分割して呼び出し
#                      （検索APIの上限件数制限を回避するため）
#   - 保存形式       : {out_dir}/{username}/YYYY-MM-DD.md
#   - 既存ファイル   : デフォルトはスキップ、-w で上書き
#
# 【コマンドラインオプション】
#   --member USERNAME   取得対象の Mattermost ユーザー名（省略時は全員）
#   --from YYYY-MM-DD   取得期間 FROM（必須）
#   --to   YYYY-MM-DD   取得期間 TO（必須）
#   --out  DIR          出力先ディレクトリ（省略時: ./work-rule-mtg/）
#   --window-days N     検索ウィンドウのサイズ（日数、省略時: 60）
#   -w                  既存ファイルを上書き
#   -k                  SSL証明書の検証をスキップ
#   -v                  詳細ログ出力
#   -h                  ヘルプ表示
#
# 【環境変数】
#   MATTERMOST_TOKEN    パーソナルアクセストークン（必須）
#   MATTERMOST_BASE_URL サーバーURL（省略時: https://chat.neogenia.co.jp/）
#   MATTERMOST_TEAM     チーム名スラッグ（省略時: Neogenia）
#   MATTERMOST_CHANNEL  チャンネル名スラッグ（省略時: team）

require "date"
require "fileutils"
require "optparse"
require "time"
require_relative "lib/mattermost_client"

DEFAULT_BASE_URL = "https://chat.neogenia.co.jp/"
DEFAULT_TEAM_NAME = "Neogenia"
DEFAULT_CHANNEL_NAME = "team"
DEFAULT_OUTPUT_DIR = "./work-rule-mtg/"
DEFAULT_WINDOW_DAYS = 60

WORK_RULE_MTG_REGEX = /アクションプラン/

class WorkRuleMtgExporter
  def initialize(client:, base_url:, team_name:, channel_name:, username:, from_date:, to_date:, out_dir:, overwrite:, window_days: DEFAULT_WINDOW_DAYS)
    @client = client
    @base_url = base_url
    @team_name = team_name
    @channel_name = channel_name
    @username = username
    @from_date = from_date
    @to_date = to_date
    @out_dir = out_dir
    @overwrite = overwrite
    @window_days = window_days
    @username_cache = {}
  end

  def run
    team_id = fetch_team_id(@team_name)
    user_id = @username ? fetch_user_id(@username) : nil

    puts "Searching #ワークルールMTG posts (#{@from_date} .. #{@to_date}) window=#{@window_days}days..."
    posts = search_work_rule_mtg_posts(team_id, user_id)
    say "Found #{posts.size} matching posts"

    stats = { saved: 0, skipped_existing: 0 }

    posts.each do |post|
      username = fetch_username_cached(post["user_id"])
      date = created_on_jst(post.fetch("create_at"))

      file_path = report_file_path(username, date)
      if File.exist?(file_path) && !@overwrite
        stats[:skipped_existing] += 1
        say "  #{date} #{username}... skipped (exists)"
        next
      end

      write_report(username, date, post, file_path)
      stats[:saved] += 1
      say "  #{date} #{username}... saved"
    end

    puts "saved=#{stats[:saved]} skipped_existing=#{stats[:skipped_existing]}"
  end

  private

  def fetch_team_id(team_name)
    @client.get("/api/v4/teams/name/#{team_name}").fetch("id")
  end

  def fetch_user_id(username)
    @client.get("/api/v4/users/username/#{username}").fetch("id")
  end

  def fetch_username_cached(user_id)
    @username_cache[user_id] ||= @client.get("/api/v4/users/#{user_id}").fetch("username")
  end

  # 指定期間を window_days 日単位のウィンドウに分割し、ウィンドウごとに検索APIを呼び出す。
  def search_work_rule_mtg_posts(team_id, user_id)
    posts = []

    date_windows(@from_date, @to_date, @window_days).each do |win_from, win_to|
      say "  searching window #{win_from} .. #{win_to}..."
      # after:/before: は境界日を含まないため、1日ずらして指定する
      terms = "アクションプラン in:#{@channel_name} after:#{win_from - 1} before:#{win_to + 1}"
      response = @client.post(
        "/api/v4/teams/#{team_id}/posts/search",
        { "terms" => terms, "is_or_search" => false }
      )
      
      order = response.fetch("order")
      next if order.empty?

      chunk = order.map { |id| response.fetch("posts").fetch(id) }

      chunk.each do |post|
        next if user_id && post["user_id"] != user_id
        unless work_rule_mtg_post?(post)
          puts '  - false'
          puts post["user_name"] 
          puts "  - message: #{post["message"]}"
          next 
        end

        posts << post
      end
    end

    posts
  end

  # 日付範囲を window_days 日単位の非重複ウィンドウに分割して返す。
  def date_windows(from_date, to_date, window_days)
    windows = []
    win_start = from_date
    while win_start <= to_date
      win_end = [win_start + window_days - 1, to_date].min
      windows << [win_start, win_end]
      win_start = win_end + 1
    end
    windows
  end

  def work_rule_mtg_post?(post)
    WORK_RULE_MTG_REGEX.match?(post["message"].to_s)
  end

  def report_file_path(username, date)
    user_dir = File.join(@out_dir, username)
    FileUtils.mkdir_p(user_dir)
    File.join(user_dir, "#{date.strftime("%Y-%m-%d")}.md")
  end

  def write_report(username, date, post, file_path)
    permalink = URI.join(@base_url, "pl/#{post.fetch("id")}").to_s
    body = <<~MD
      # Work Rule Meeting Reflection
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

  def created_on_jst(ms)
    Time.at(ms / 1000.0).getlocal(JST_OFFSET).to_date
  end
end

def parse_args(argv)
  options = {
    base_url: ENV.fetch("MATTERMOST_BASE_URL", DEFAULT_BASE_URL),
    team_name: ENV.fetch("MATTERMOST_TEAM", DEFAULT_TEAM_NAME),
    channel_name: ENV.fetch("MATTERMOST_CHANNEL", DEFAULT_CHANNEL_NAME),
    out_dir: DEFAULT_OUTPUT_DIR,
    window_days: DEFAULT_WINDOW_DAYS,
    overwrite: false,
    verify_ssl: false,
    verbose: false
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby export_work-rule_refrection.rb --from 2026-04-01 --to 2026-04-22 [options]"

    opts.on("--member USERNAME", "Mattermost username (省略時は全ユーザーが対象)") do |value|
      options[:member] = value.strip
    end

    opts.on("--from YYYY-MM-DD", "Start date in JST") do |value|
      options[:from] = Date.strptime(value, "%Y-%m-%d")
    end

    opts.on("--to YYYY-MM-DD", "End date in JST") do |value|
      options[:to] = Date.strptime(value, "%Y-%m-%d")
    end

    opts.on("--out DIR", "Output directory (default: #{DEFAULT_OUTPUT_DIR})") do |value|
      options[:out_dir] = value
    end

    opts.on("--window-days N", Integer, "Search window size in days (default: #{DEFAULT_WINDOW_DAYS})") do |value|
      options[:window_days] = value
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

  required = %i[from to]
  missing = required.select { |key| options[key].nil? }
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
  exporter = WorkRuleMtgExporter.new(
    client: client,
    base_url: options[:base_url],
    team_name: options[:team_name],
    channel_name: options[:channel_name],
    username: options[:member],
    from_date: options[:from],
    to_date: options[:to],
    out_dir: options[:out_dir],
    overwrite: options[:overwrite],
    window_days: options[:window_days]
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
