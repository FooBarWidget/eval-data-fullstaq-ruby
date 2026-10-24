#!/usr/bin/env ruby
require 'minitest/autorun'
require_relative '../lib/package_version_order'

describe PackageVersionOrder do
  it 'follows package-manager ordering rather than SemVer' do
    [[:deb, '1.9-9', '1.10-0'], [:deb, '1.0-9', '1.0.0-0'],
      [:deb, '1.1.2-9-9', '1.1.2-10-0'], [:deb, '1.0~rc1-0', '1.0-0'],
      [:deb, '1.0+0-0', '1.0.0-0'], [:deb, '100-9', '1:0.1-0'],
      [:rpm, '1.9-9', '1.10-0'], [:rpm, '1.0-9', '1.0.0-0'],
      [:rpm, '1.1.2_9-9', '1.1.2_10-0'], [:rpm, '1.0~rc1-0', '1.0-0'],
      [:rpm, '1.0-0', '1.0^git1-0'], [:rpm, '1.0^git1-0', '1.0.1-0'],
      [:rpm, '1.a-0', '1.0-0'], [:rpm, '100-9', '1:0.1-0']].each do |format, older, newer|
      assert_equal(-1, PackageVersionOrder.compare(format, older, newer), "#{format}: #{older} < #{newer}")
      assert_equal(1, PackageVersionOrder.compare(format, newer, older), "#{format}: #{newer} > #{older}")
    end
  end

  it 'recognizes equivalent package-manager versions' do
    assert_equal 0, PackageVersionOrder.compare(:deb, '1.01-0', '1.1-00')
    assert_equal 0, PackageVersionOrder.compare(:rpm, '1.01-0', '1.1-00')
    assert_equal 0, PackageVersionOrder.compare(:rpm, '1.0+0-0', '1.0.0-0')
  end
end
