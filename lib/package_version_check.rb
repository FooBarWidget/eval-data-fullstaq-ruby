require 'digest/md5'
require_relative 'package_version_order'

# Package upgrade policy, independent of Git and the approval service. It
# distinguishes mandatory upgrade rules from build changes needing human review.
class PackageVersionCheck
  # Each review group shares a set of builder files and one approval checksum.
  # Group names are part of the existing external approval protocol.
  REVIEW_FILES = {
    'common-deb-version-revision' => ['container-entrypoints/build-common-deb'],
    'common-rpm-version-revision' => ['container-entrypoints/build-common-rpm'],
    'rbenv-package-revision' => %w[container-entrypoints/build-rbenv-deb container-entrypoints/build-rbenv-rpm],
    'ruby-package-revisions' => %w[container-entrypoints/build-jemalloc container-entrypoints/build-ruby container-entrypoints/build-ruby-deb container-entrypoints/build-ruby-rpm]
  }.freeze

  # One record per package name/format, rather than per distro or variant:
  # those builds share the version settings being checked here. Ruby records
  # use the revision-only scheme: their Ruby release is in the package name.
  # They need no format-specific comparison because both DEB and RPM order
  # their integer revisions alike. Common/Rbenv use upstream version + revision.
  # source identifies upstream inputs; component identifies the review group.
  Package = Struct.new(:name, :format, :version_scheme, :version, :revision, :source, :component, keyword_init: true) do
    def revision_only?
      version_scheme == :revision_only
    end

    def label
      format ? "#{name} (#{format.to_s.upcase})" : name
    end

    def package_version
      return revision.to_s if revision_only?
      # Match FPM's RPM version normalization before comparing upgrade order.
      upstream = format == :rpm ? version.tr('-', '_') : version
      "#{upstream}-#{revision}"
    end

    def compare(other)
      return revision <=> other.revision if revision_only?
      PackageVersionOrder.compare(format, package_version, other.package_version)
    end
  end

  attr_reader :packages

  def initialize(config)
    @packages = {}
    ruby = config.fetch('ruby')
    (ruby['minor_version_packages'] || []).each do |entry|
      add_ruby_package(entry.fetch('minor_version'), entry, config['jemalloc_version'])
    end
    (ruby['tiny_version_packages'] || []).each do |entry|
      add_ruby_package(entry.fetch('full_version'), entry, config['jemalloc_version'])
    end
    [:deb, :rpm].each do |format|
      entry = config.fetch('common').fetch(format.to_s)
      add_package('fullstaq-ruby-common', format, entry, nil, "common-#{format}-version-revision")
      entry = config.fetch('rbenv')
      source = { repo: entry['repo'], ref: entry['ref'], path: entry['path'] }
      add_package('fullstaq-rbenv', format, entry, source, 'rbenv-package-revision')
    end
  end

  # Compare only package identities present in both configurations. New names
  # may start at revision zero; removing a name is allowed. For existing names,
  # equal versions are safe only when their upstream inputs are unchanged.
  def errors_against(baseline)
    errors = []
    packages.each do |key, current|
      previous = baseline.packages[key]
      next unless previous
      comparison = current.compare(previous)
      if comparison.negative?
        errors << "#{current.label}: package version must not decrease (#{display(previous)} -> #{display(current)})"
      elsif comparison.zero? && current.source != previous.source
        errors << "#{current.label}: source changed without a higher package version; increase package_revision"
      end
    end
    errors
  end

  # Return review-group => affected package labels, not policy errors. A script
  # change may be a harmless refactor, so unchanged package versions require
  # human review. New or bumped packages already get a distinct package version.
  # Callers must enforce errors_against before allowing any approval to apply.
  def reviews_against(baseline, changed_files)
    reviews = {}
    REVIEW_FILES.each do |component, files|
      next if (files & changed_files).empty?
      unchanged = packages.filter_map do |key, current|
        previous = baseline.packages[key]
        current.label if current.component == component && previous && current.compare(previous).zero?
      end
      reviews[component] = unchanged unless unchanged.empty?
    end
    reviews
  end

  # Bind approval to the project, review group, release baseline and builder
  # contents. Preserve the original shell protocol's headers, ordering and
  # sha256sum line format so previously issued approvals remain valid.
  def self.approval_checksum(component, base_ref, file_checksums)
    lines = ["project=fullstaq-ruby-server-edition", "component=#{component}", "base=#{base_ref}"]
    REVIEW_FILES.fetch(component).sort.each do |path|
      lines << "#{file_checksums.fetch(path)}  #{path}"
    end
    Digest::MD5.hexdigest(lines.join("\n") + "\n")
  end

private
  def add_ruby_package(id, entry, jemalloc_version)
    name = "fullstaq-ruby-#{id}"
    source = { ruby_version: entry.fetch('full_version'), jemalloc_version: jemalloc_version }
    package = Package.new(name: name, version_scheme: :revision_only, revision: revision(entry, name), source: source,
      component: 'ruby-package-revisions')
    add(package)
  end

  def add_package(name, format, entry, source, component)
    package = Package.new(name: name, format: format, version_scheme: :upstream_with_revision, version: entry.fetch('version').to_s,
      revision: revision(entry, name), source: source, component: component)
    PackageVersionOrder.split(format, package.package_version)
    add(package)
  end

  def add(package)
    key = [package.name, package.format]
    raise ArgumentError, "Duplicate package: #{package.label}" if packages.key?(key)
    packages[key] = package
  end

  def revision(entry, name)
    value = entry.fetch('package_revision')
    unless (value.is_a?(String) || value.is_a?(Integer)) && value.to_s.match?(/\A[0-9]+\z/)
      raise ArgumentError, "#{name}: package_revision must be a non-negative integer"
    end
    value.to_i
  end

  def display(package)
    package.revision_only? ? "revision #{package.revision}" : package.package_version
  end
end
