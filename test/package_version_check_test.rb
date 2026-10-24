#!/usr/bin/env ruby
require 'minitest/autorun'
require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'yaml'
require_relative '../lib/package_version_check'
require_relative '../internal-scripts/ci-cd/check-version-numbers-need-changing/check-package-versions'

describe PackageVersionCheck do
  it 'requires revisions to keep increasing across Ruby patch releases' do
    before = config.merge(fixture('minor-packages-baseline'))
    current = config.merge(fixture('minor-packages-reset-revisions'))
    errors = check(current).errors_against(check(before))
    assert_equal 3, errors.size
    %w[4.0 3.4 3.3].each { |minor| assert errors.any? { |error| error.include?("fullstaq-ruby-#{minor}:") } }

    current['ruby']['minor_version_packages'].zip([5, 10, 13]).each do |entry, revision|
      entry['package_revision'] = revision
    end
    assert_empty check(current).errors_against(check(before))
  end

  it 'rejects revision decreases for every package family' do
    current = config
    set_revisions(current, 3)
    errors = check(current).errors_against(check(config))
    assert_equal 6, errors.size
    ['fullstaq-ruby-4.0:', 'fullstaq-ruby-4.0.6:', 'fullstaq-ruby-common (DEB)',
      'fullstaq-ruby-common (RPM)', 'fullstaq-rbenv (DEB)', 'fullstaq-rbenv (RPM)'].each do |label|
      assert errors.any? { |error| error.include?(label) }, "Missing regression check for #{label}"
    end
  end

  it 'allows unchanged packages and numeric revision increases' do
    before = config
    set_revisions(before, '9')
    assert_empty check(before).errors_against(check(before))
    current = config
    set_revisions(current, 10)
    assert_empty check(current).errors_against(check(before))
  end

  it 'requires a strictly higher revision when a minor Ruby package changes its Ruby release' do
    current = config
    entry = current['ruby']['minor_version_packages'].first
    entry['full_version'] = '4.0.9'
    assert_affected_packages ['fullstaq-ruby-4.0'], check(current).errors_against(check(config))
    entry['package_revision'] = 5
    assert_empty check(current).errors_against(check(config))
  end

  it 'allows new package names to start at zero and old names to be removed' do
    current = config
    current['ruby'] = {
      'minor_version_packages' => [{ 'minor_version' => '4.1', 'full_version' => '4.1.0', 'package_revision' => 0 }],
      'tiny_version_packages' => [{ 'full_version' => '4.1.0', 'package_revision' => 0 }]
    }
    assert_empty check(current).errors_against(check(config))
    current['ruby'] = {}
    assert_empty check(current).errors_against(check(config))
  end

  it 'allows common and Rbenv revision resets only with higher package versions' do
    current = config
    current['common'].each_value { |entry| entry.merge!('version' => '1.10', 'package_revision' => 0) }
    current['rbenv'].merge!('version' => '1.1.2-17', 'package_revision' => 0)
    assert_empty check(current).errors_against(check(config))

    current['common'].each_value { |entry| entry.merge!('version' => '0.9', 'package_revision' => 99) }
    current['rbenv'].merge!('version' => '1.1.2-15', 'package_revision' => 99)
    assert_affected_packages ['fullstaq-ruby-common (DEB)', 'fullstaq-ruby-common (RPM)',
      'fullstaq-rbenv (DEB)', 'fullstaq-rbenv (RPM)'], check(current).errors_against(check(config))
  end

  it 'requires a higher package version when Rbenv sources change' do
    current = config
    current['rbenv']['ref'] = 'new-source'
    assert_affected_packages ['fullstaq-rbenv (DEB)', 'fullstaq-rbenv (RPM)'], check(current).errors_against(check(config))
    current['rbenv']['package_revision'] = 5
    assert_empty check(current).errors_against(check(config))
  end

  it 'requires higher Ruby revisions when Jemalloc changes' do
    current = config
    current['jemalloc_version'] = '5.3.0'
    assert_affected_packages ['fullstaq-ruby-4.0', 'fullstaq-ruby-4.0.6'], check(current).errors_against(check(config))
  end

  it 'represents revision-only and upstream-version packages with meaningful version strings' do
    versions = check(config).packages.values.to_h { |package| [package.label, package.package_version] }
    assert_equal({
      'fullstaq-ruby-4.0' => '4', 'fullstaq-ruby-4.0.6' => '4',
      'fullstaq-ruby-common (DEB)' => '1.0-4', 'fullstaq-ruby-common (RPM)' => '1.0-4',
      'fullstaq-rbenv (DEB)' => '1.1.2-16-4', 'fullstaq-rbenv (RPM)' => '1.1.2_16-4'
    }, versions)
  end

  it 'requires script-change review only for packages without a version bump' do
    current = config
    component = 'common-deb-version-revision'
    changed_files = ['container-entrypoints/build-common-deb']
    assert_equal({ component => ['fullstaq-ruby-common (DEB)'] },
      check(current).reviews_against(check(config), changed_files))
    assert_empty check(current).reviews_against(check(config), ['README.md'])
    current['common']['deb']['package_revision'] = 5
    assert_empty check(current).reviews_against(check(config), changed_files)
  end

  it 'preserves existing approval checksums' do
    # Existing shell protocol, for an empty build-common-deb and epic-3.59.
    hashes = { 'container-entrypoints/build-common-deb' => 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }
    assert_equal 'c06a71f58cc9f95f75d44f6a1eacd19d',
      PackageVersionCheck.approval_checksum('common-deb-version-revision', 'epic-3.59', hashes)
  end

  it 'allows manual approval to waive script review but not a downgrade' do
    Dir.mktmpdir('package-version-review-') do |directory|
      File.write("#{directory}/config.yml", YAML.dump(config))
      FileUtils.mkdir_p("#{directory}/container-entrypoints")
      build_script = "#{directory}/container-entrypoints/build-common-deb"
      File.write(build_script, '# Original builder')
      git(directory, 'init', '-q')
      git(directory, 'add', 'container-entrypoints/build-common-deb')
      commit(directory)
      git(directory, 'tag', 'published')
      File.write(build_script, '')

      approvals = []
      app = PackageVersionCheckApp.new
      app.define_singleton_method(:fetch_approvals) { approvals }
      Dir.chdir(directory) do
        _output, error = capture_io { refute app.run(['published'], {}) }
        assert_includes error, 'build scripts changed without a higher package version'

        # Legacy checksum for the empty builder at the published baseline.
        approvals << '231530cbd4009f163d2c4042441a40d7'
        capture_io { assert app.run(['published'], {}) }

        current = config
        current['common']['deb']['package_revision'] = 3
        File.write('config.yml', YAML.dump(current))
        _output, error = capture_io { refute app.run(['published'], {}) }
        assert_includes error, 'package version must not decrease'
      end
    end
  end

  it 'rejects invalid revisions and duplicate package names' do
    [-1, 1.5, nil].each do |revision|
      current = config
      current['common']['rpm']['package_revision'] = revision
      assert_raises(ArgumentError) { check(current) }
    end
    current = config
    current['ruby']['minor_version_packages'] << current['ruby']['minor_version_packages'].first.dup
    assert_raises(ArgumentError) { check(current) }
  end

  it 'preserves exception details and the backtrace when configuration parsing fails' do
    Dir.mktmpdir('package-version-invalid-config-') do |directory|
      File.write("#{directory}/config.yml", 'ruby: [')
      _output, error, status = run_cli(directory, {})
      refute_predicate status, :success?
      assert_includes error, 'Psych::SyntaxError'
      assert_includes error, 'config.yml'
      assert_match(/check-package-versions\.rb:\d+:in/, error)
    end
  end

  it 'rejects CLI revisions below the default branch even when the release permits them' do
    with_cli_repository do |directory, published_sha, _main_sha|
      write_revisions(directory, 4)
      _output, error, status = run_cli(directory, 'GITHUB_REF' => 'refs/heads/feature', 'BEFORE_SHA' => published_sha)
      refute_predicate status, :success?
      assert_includes error, 'Compared to refs/remotes/origin/main:'
    end
  end

  it 'compares default-branch pushes against their pre-push state through the CLI' do
    with_cli_repository do |directory, _published_sha, main_sha|
      write_revisions(directory, 4)
      commit(directory)
      git(directory, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
      _output, error, status = run_cli(directory, 'GITHUB_REF' => 'refs/heads/main', 'BEFORE_SHA' => main_sha)
      refute_predicate status, :success?
      assert_includes error, "Compared to #{main_sha}:"
    end
  end

  it 'uses the default branch for manual runs and null previous object IDs of any hash length' do
    with_cli_repository do |directory, _published_sha, _main_sha|
      write_revisions(directory, 5)
      ['', '0' * 40, '0' * 64, '0' * 128].each do |before_sha|
        output, error, status = run_cli(directory, 'GITHUB_REF' => 'refs/heads/main', 'BEFORE_SHA' => before_sha)
        assert_predicate status, :success?, output + error
      end
    end
  end

  it 'rejects CLI revisions below the release even when the default branch permits them' do
    with_cli_repository do |directory, _published_sha, _main_sha|
      write_revisions(directory, 9)
      commit(directory)
      git(directory, 'tag', '-f', 'published')
      write_revisions(directory, 8)
      _output, error, status = run_cli(directory, 'GITHUB_REF' => 'refs/heads/feature')
      refute_predicate status, :success?
      assert_includes error, 'Compared to published:'
    end
  end

private
  def assert_affected_packages(expected, errors)
    assert_equal expected.sort, errors.map { |error| error.split(':', 2).first }.sort
  end

  # Published packages are at revision 4; the default branch has advanced to 5.
  # Each example gets its own repository so its history changes stay local.
  def with_cli_repository
    Dir.mktmpdir('package-version-check-') do |directory|
      git(directory, 'init', '-q')
      write_revisions(directory, 4)
      commit(directory)
      git(directory, 'tag', 'published')
      published_sha = git(directory, 'rev-parse', 'HEAD').strip
      write_revisions(directory, 5)
      commit(directory)
      main_sha = git(directory, 'rev-parse', 'HEAD').strip
      git(directory, 'update-ref', 'refs/remotes/origin/main', main_sha)
      yield directory, published_sha, main_sha
    end
  end

  def write_revisions(directory, revision)
    current = config
    set_revisions(current, revision)
    File.write("#{directory}/config.yml", YAML.dump(current))
  end

  def config
    {
      'ruby' => {
        'minor_version_packages' => [{ 'minor_version' => '4.0', 'full_version' => '4.0.6', 'package_revision' => 4 }],
        'tiny_version_packages' => [{ 'full_version' => '4.0.6', 'package_revision' => 4 }]
      },
      'common' => { 'deb' => { 'version' => '1.0', 'package_revision' => 4 },
                    'rpm' => { 'version' => '1.0', 'package_revision' => 4 } },
      'rbenv' => { 'repo' => 'https://example.com/rbenv', 'ref' => 'old-source', 'version' => '1.1.2-16', 'package_revision' => 4 },
      'jemalloc_version' => '3.6.0'
    }
  end

  def check(config)
    PackageVersionCheck.new(config)
  end

  def set_revisions(config, revision)
    entries = config['ruby'].values.flatten + config['common'].values + [config['rbenv']]
    entries.each { |entry| entry['package_revision'] = revision }
  end

  def fixture(name)
    YAML.safe_load_file(File.join(__dir__, 'fixtures/package-versions', "#{name}.yml"))
  end

  def git(directory, *args)
    output, error, status = Open3.capture3('git', *args, chdir: directory)
    raise error unless status.success?
    output
  end

  def commit(directory)
    git(directory, 'add', 'config.yml')
    git(directory, '-c', 'user.name=Version test', '-c', 'user.email=test@example.invalid',
      '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Package versions')
  end

  def run_cli(directory, env)
    script = File.expand_path('../internal-scripts/ci-cd/check-version-numbers-need-changing/check-package-versions.rb', __dir__)
    env = { 'LATEST_RELEASE_TAG' => 'published', 'DEFAULT_BRANCH' => 'main', 'BEFORE_SHA' => '' }.merge(env)
    Open3.capture3(env, RbConfig.ruby, script, chdir: directory)
  end
end
