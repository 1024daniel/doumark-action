#!/usr/bin/env ruby

require "csv"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "pathname"
require "tempfile"
require "time"
require "uri"

DATA_DIR = ARGV.fetch(0, "data/douban")
POSTER_DIR = File.join(DATA_DIR, "posters")
POSTER_SOURCE = ENV["DOUBAN_POSTER_SOURCE"]
DOUBAN_API_HOST = ENV.fetch("DOUBAN_API_HOST", "frodo.douban.com")
DOUBAN_API_KEY = ENV.fetch("DOUBAN_API_KEY", "0ac44ae016490db2204ce0a042db2916")
DOUBAN_ID = ENV["DOUBAN_ID"]
REFRESH_DAYS = Integer(ENV.fetch("DOUBAN_POSTER_REFRESH_DAYS", "30"))
MAX_IMAGE_BYTES = 10 * 1024 * 1024

def fetch(uri, redirects: 3)
  raise "too many redirects" if redirects.negative?

  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "Mozilla/5.0 (GitHub Actions; doumark-action)"
  request["Referer"] = "https://movie.douban.com/"

  Net::HTTP.start(
    uri.host,
    uri.port,
    use_ssl: uri.scheme == "https",
    open_timeout: 10,
    read_timeout: 30
  ) do |http|
    response = http.request(request)
    case response
    when Net::HTTPSuccess
      content_type = response["content-type"].to_s.downcase
      body = response.body
      raise "unexpected content type #{content_type.inspect}" unless content_type.start_with?("image/")
      raise "empty image" if body.nil? || body.empty?
      raise "image exceeds #{MAX_IMAGE_BYTES} bytes" if body.bytesize > MAX_IMAGE_BYTES

      body
    when Net::HTTPRedirection
      location = response["location"]
      raise "redirect without location" if location.nil? || location.empty?

      fetch(URI.join(uri.to_s, location), redirects: redirects - 1)
    else
      raise "HTTP #{response.code}"
    end
  end
end

def fetch_cover_urls(type)
  return {} if DOUBAN_ID.nil? || DOUBAN_ID.empty?

  covers = {}
  offset = 0
  page_size = 50

  loop do
    query = URI.encode_www_form(
      type: type,
      status: "done",
      count: page_size,
      start: offset,
      apiKey: DOUBAN_API_KEY
    )
    uri = URI("https://#{DOUBAN_API_HOST}/api/v2/user/#{DOUBAN_ID}/interests?#{query}")
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "User-Agent: Mozilla/5.0 (iPhone; CPU iPhone OS 15_3 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.16(0x18001023) NetType/WIFI Language/zh_CN"
    request["Referer"] = "https://servicewechat.com/wx2f9b06c1de1ccfca/84/page-frame.html"

    response = Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: true,
      open_timeout: 10,
      read_timeout: 30
    ) { |http| http.request(request) }
    raise "Douban API HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    interests = data.fetch("interests", [])
    interests.each do |interest|
      subject = interest["subject"] || {}
      cover = subject["cover_url"] || subject.dig("pic", "large")
      covers[subject["id"].to_s] = cover if cover && !cover.empty?
    end

    offset += interests.length
    break if interests.length < page_size || offset >= data.fetch("total", offset)

    sleep 1
  end

  covers
end

def refresh_poster(type, id, destination, cover_url)
  return false if File.exist?(destination) && File.mtime(destination) > Time.now - REFRESH_DAYS * 86_400

  source_url = cover_url
  source_url ||= "#{POSTER_SOURCE}/#{type}/#{id}.jpg" if POSTER_SOURCE && !POSTER_SOURCE.empty?
  return false unless source_url

  FileUtils.mkdir_p(File.dirname(destination))
  source = URI(source_url)
  image = nil
  error = nil

  3.times do |attempt|
    begin
      image = fetch(source)
      break
    rescue StandardError => e
      error = e
      sleep(2**attempt)
    end
  end

  raise error unless image

  Tempfile.create(["poster-", ".jpg"], File.dirname(destination)) do |file|
    file.binmode
    file.write(image)
    file.flush
    File.rename(file.path, destination)
  end

  true
end

def github_poster_url(relative_path, digest)
  repository = ENV["GITHUB_REPOSITORY"]
  branch = ENV["GITHUB_REF_NAME"]
  return relative_path unless repository && branch
  return relative_path if relative_path == ".." || relative_path.start_with?("../")

  "https://raw.githubusercontent.com/#{repository}/#{branch}/#{relative_path}?v=#{digest}"
end

downloaded = 0
available_covers = 0

Dir.glob(File.join(DATA_DIR, "*.csv")).sort.each do |path|
  type = File.basename(path, ".csv")
  table = CSV.read(path, headers: true)
  next unless table.headers&.include?("id")

  cover_urls = fetch_cover_urls(type)
  available_covers += cover_urls.length
  puts "Found #{cover_urls.length} current #{type} cover URLs from Douban"

  # The sync output is newest-first, so keep the first occurrence of each ID.
  rows = {}
  table.each do |row|
    id = row["id"].to_s.strip
    next if id.empty? || rows.key?(id)

    destination = File.join(POSTER_DIR, type, "#{id}.jpg")
    begin
      downloaded += 1 if refresh_poster(type, id, destination, cover_urls[id])
    rescue StandardError => e
      warn "Poster #{type}/#{id} was not refreshed: #{e.message}"
    end

    if File.exist?(destination)
      relative_path = Pathname.new(File.expand_path(destination))
                              .relative_path_from(Pathname.new(Dir.pwd))
                              .to_s
      digest = Digest::SHA256.file(destination).hexdigest[0, 12]
      row["poster"] = github_poster_url(relative_path, digest)
    end

    rows[id] = row
  end

  CSV.open(path, "w", write_headers: true, headers: table.headers) do |csv|
    rows.each_value { |row| csv << row }
  end
end


puts "Downloaded #{downloaded} posters; #{available_covers} direct cover URLs were available"
cached_posters = Dir.glob(File.join(POSTER_DIR, "**", "*.jpg")).length
if available_covers.positive? && downloaded.zero? && cached_posters.zero?
  raise "No posters were downloaded despite direct cover URLs being available"
end
