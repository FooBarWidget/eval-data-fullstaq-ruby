#!/usr/bin/env ruby
require 'net/http'
require 'open3'
require 'yaml'
require 'digest/sha2'
require_relative '../../../lib/package_version_check'

# CI entry point: enforce mandatory upgrade rules first, then resolve reviews
# for build-script changes whose effect on package contents needs human judgment.
class PackageVersionCheckApp
  APPROVALS_URL = 'https://raw.githubusercontent.com/fullstaq-labs/fullstaq-ruby-ci-approvals/main/approvals.txt'
  APPROVALS_EDIT_URL = 'https://github.com/fullstaq-labs/fullstaq-ruby-ci-approvals/edit/main/approvals.txt'

  def run(refs = ARGV, env = ENV)
    current = load_config(File.read('config.yml', encoding: 'utf-8'), filename: 'config.yml')

    # Protect both unreleased branch changes and already published packages.
    # Neither baseline alone necessarily contains the highest package versions.
    comparison_refs, release_ref = comparison_baselines(refs, env)
    baselines = load_baselines(comparison_refs)

    # Downgrades and unbumped source changes are unconditional failures.
    # Stop before consulting approvals: human review cannot waive these rules.
    errors = version_errors(current, baselines)
    return fail_check(errors) unless errors.empty?

    # A build-script diff might change the package, or just refactor its builder.
    # Review the cumulative diff since publication, not an intermediate commit
    # that might already contain some of the unreviewed changes.
    release = baselines.fetch(release_ref)
    reviews = current.reviews_against(release, changed_build_scripts(release_ref))
    errors = unapproved_review_errors(reviews, release_ref)
    return fail_check(errors) unless errors.empty?

    puts "All package versions and revisions are valid against #{baselines.keys.join(', ')}."
    true
  end

private
  # CI supplies the release tag. Explicit local refs override branch selection;
  # without a release tag, the last explicit ref also serves as the review base.
  def comparison_baselines(refs, env)
    release_ref = env['LATEST_RELEASE_TAG']
    release_ref = nil if release_ref.to_s.empty?
    if refs.empty?
      raise ArgumentError, 'LATEST_RELEASE_TAG is required (or pass baseline Git refs as arguments)' if release_ref.to_s.empty?
      refs = [branch_baseline(env), release_ref]
    end
    [(refs + [release_ref].compact).uniq, release_ref || refs.last]
  end

  def load_baselines(refs)
    refs.to_h do |ref|
      [ref, load_config(git('show', "#{ref}:config.yml"), filename: "#{ref}:config.yml")]
    end
  end

  def version_errors(current, baselines)
    baselines.flat_map do |ref, baseline|
      current.errors_against(baseline).map { |error| "Compared to #{ref}: #{error}" }
    end
  end

  def changed_build_scripts(release_ref)
    files = PackageVersionCheck::REVIEW_FILES.values.flatten.uniq
    git('diff', '--name-only', release_ref, '--', *files).lines.map(&:chomp)
  end

  def unapproved_review_errors(reviews, release_ref)
    # Ordinary version-only updates need no approval service access.
    return [] if reviews.empty?

    approvals = fetch_approvals
    errors = []
    reviews.each do |component, packages|
      checksum = review_checksum(component, release_ref)
      next if approvals.include?(checksum)
      errors << "#{packages.join(', ')}: build scripts changed without a higher package version. " \
        "Bump the version/revision, or review the diff against #{release_ref} and, only if package contents " \
        "and metadata are unchanged, add #{checksum} at #{APPROVALS_EDIT_URL}."
    end
    errors
  end

  # An approval covers a review group at one release baseline and the exact
  # contents of all its builder files. Editing any of them invalidates approval.
  def review_checksum(component, release_ref)
    checksums = PackageVersionCheck::REVIEW_FILES.fetch(component).to_h do |path|
      [path, Digest::SHA256.file(path).hexdigest]
    end
    PackageVersionCheck.approval_checksum(component, release_ref, checksums)
  end

  def branch_baseline(env)
    default_branch = env.fetch('DEFAULT_BRANCH', 'main')
    before = env['BEFORE_SHA'].to_s
    # On a default-branch push, origin already points at this run's commit.
    # A new branch has a null previous ID, independent of the hash algorithm.
    if env['GITHUB_REF'] == "refs/heads/#{default_branch}" && !before.empty? && !before.match?(/\A0+\z/)
      before
    else
      "refs/remotes/origin/#{default_branch}"
    end
  end

  def load_config(yaml, filename:)
    PackageVersionCheck.new(YAML.safe_load(yaml, filename: filename))
  end

  def git(*args)
    output, error, status = Open3.capture3('git', *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?
    output
  end

  def fetch_approvals
    uri = URI(APPROVALS_URL)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
      http.get(uri.request_uri)
    end
    unless response.is_a?(Net::HTTPSuccess)
      raise "Fetching approvals from #{uri} failed: HTTP #{response.code} #{response.message}"
    end
    response.body.lines.map(&:chomp)
  end

  def fail_check(errors)
    errors.each { |error| warn "ERROR: #{error}" }
    false
  end
end

if $PROGRAM_NAME == __FILE__
  exit(PackageVersionCheckApp.new.run ? 0 : 1)
end
