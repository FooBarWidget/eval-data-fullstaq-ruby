#!/usr/bin/env ruby
# Optional cross-check against host dpkg and RPM's published comparison cases.
# Requires dpkg and network access; not part of the offline unit test runner.
require 'net/http'
require 'open3'
require_relative '../lib/package_version_order'

def verify_comparison(format, left, right, expected)
  actual = PackageVersionOrder.compare(format, left, right)
  raise "#{format}: #{left} vs #{right}: expected #{expected}, got #{actual}" unless actual == expected
end

def dpkg_compare(left, operator, right)
  _output, error, status = Open3.capture3('dpkg', '--compare-versions', left, operator, right)
  # dpkg uses 1 for a false comparison, and 2 for an actual error.
  raise "dpkg comparison failed: #{error}" unless [0, 1].include?(status.exitstatus)
  status.success?
end

versions = %w[0-0 00-0 1-0 1.0-0 1.00-0 1.0.0-0 1.0~rc1-0 1.0+git-0
  1.0-1-0 1.0-2-0 1.0a-0 1.0+0-0 1:0.1-0 2.0-0 1.0~~-0 1.0~rc1~git-0
  1.1.2-9-9 1.1.2-10-0]
versions.product(versions).each do |left, right|
  expected = if dpkg_compare(left, 'lt', right)
    -1
  elsif dpkg_compare(left, 'gt', right)
    1
  else
    0
  end
  verify_comparison(:deb, left, right, expected)
end
puts "Passed #{versions.size ** 2} comparisons against host dpkg."

uri = URI('https://raw.githubusercontent.com/rpm-software-management/rpm/rpm-4.18.0-release/tests/rpmvercmp.at')
response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
  http.get(uri.request_uri)
end
raise "Fetching #{uri} failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
cases = response.body.scan(/^RPMVERCMP\(([^,]+), ([^,]+), (-?\d+)\)$/)
raise "No comparison cases found at #{uri}" if cases.empty?
cases.each do |left, right, expected|
  verify_comparison(:rpm, "#{left}-0", "#{right}-0", expected.to_i)
end
puts "Passed #{cases.size} upstream RPM comparison cases."
