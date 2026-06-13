#!/usr/bin/env ruby

require "csv"
require "digest"
require "fileutils"
require "net/http"
require "pathname"
require "tempfile"
require "time"
require "uri"

DATA_DIR = ARGV.fetch(0, "data/douban")
POSTER_DIR = File.join(DATA_DIR, "posters")
POSTER_SOURCE = ENV.fetch("DOUBAN_POSTER_SOURCE", "https://dou.img.lithub.cc")
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

def refresh_poster(type, id, destination)
  return if File.exist?(destination) && File.mtime(destination) > Time.now - REFRESH_DAYS * 86_400

  FileUtils.mkdir_p(File.dirname(destination))
  source = URI("#{POSTER_SOURCE}/#{type}/#{id}.jpg?v=#{Time.now.utc.strftime('%Y%m')}")
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
end

def github_poster_url(relative_path, digest)
  repository = ENV["GITHUB_REPOSITORY"]
  branch = ENV["GITHUB_REF_NAME"]
  return relative_path unless repository && branch
  return relative_path if relative_path == ".." || relative_path.start_with?("../")

  "https://raw.githubusercontent.com/#{repository}/#{branch}/#{relative_path}?v=#{digest}"
end

Dir.glob(File.join(DATA_DIR, "*.csv")).sort.each do |path|
  type = File.basename(path, ".csv")
  table = CSV.read(path, headers: true)
  next unless table.headers&.include?("id")

  # The sync output is newest-first, so keep the first occurrence of each ID.
  rows = {}
  table.each do |row|
    id = row["id"].to_s.strip
    next if id.empty? || rows.key?(id)

    destination = File.join(POSTER_DIR, type, "#{id}.jpg")
    begin
      refresh_poster(type, id, destination)
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
