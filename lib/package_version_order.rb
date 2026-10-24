require 'strscan'

# Compare the versions emitted by FPM, not RubyGems/SemVer versions. Debian
# and RPM differ in punctuation, prereleases and numeric-segment ordering.
# See Debian Policy 5.6.12 and rpm-version(7).
module PackageVersionOrder
  extend self

  def compare(format, left, right)
    left_parts = split(format, left)
    right_parts = split(format, right)
    result = left_parts[0] <=> right_parts[0]
    return result unless result.zero?

    [1, 2].each do |index|
      result = format == :deb ? compare_debian_part(left_parts[index], right_parts[index]) :
        compare_rpm_part(left_parts[index], right_parts[index])
      return result unless result.zero?
    end
    0
  end

  def split(format, version)
    pattern = if format == :deb
      /\A(?:(\d+):)?([0-9][A-Za-z0-9.+~\-]*)-(\d+)\z/
    else
      /\A(?:(\d+):)?([A-Za-z0-9._+~^]+)-(\d+)\z/
    end
    match = pattern.match(version)
    raise ArgumentError, "Invalid #{format.to_s.upcase} package version: #{version.inspect}" unless match
    [match[1].to_i, match[2], match[3]]
  end

private
  def compare_debian_part(left, right)
    left = StringScanner.new(left)
    right = StringScanner.new(right)
    until left.eos? && right.eos?
      # Debian alternates modified ASCII ordering and numeric ordering.
      while non_digit?(left.peek(1)) || non_digit?(right.peek(1))
        result = debian_character_order(left.peek(1)) <=> debian_character_order(right.peek(1))
        return result unless result.zero?
        left.getch
        right.getch
      end
      result = left.scan(/\d*/).to_i <=> right.scan(/\d*/).to_i
      return result unless result.zero?
    end
    0
  end

  def non_digit?(character)
    !character.empty? && !character.match?(/[0-9]/)
  end

  def debian_character_order(character)
    return -1 if character == '~'
    return 0 if character.empty? || character.match?(/[0-9]/)
    return character.ord if character.match?(/[A-Za-z]/)
    character.ord + 256
  end

  def compare_rpm_part(left, right)
    left = StringScanner.new(left)
    right = StringScanner.new(right)
    loop do
      left.skip(/[._+]+/)
      right.skip(/[._+]+/)

      # Tilde sorts before the base release; caret denotes a snapshot after
      # that release but before its next ordinary segment.
      if left.peek(1) == '~' || right.peek(1) == '~'
        return 1 unless left.peek(1) == '~'
        return -1 unless right.peek(1) == '~'
        left.getch
        right.getch
        next
      end
      if left.peek(1) == '^' || right.peek(1) == '^'
        return -1 if left.eos?
        return 1 if right.eos?
        return 1 unless left.peek(1) == '^'
        return -1 unless right.peek(1) == '^'
        left.getch
        right.getch
        next
      end

      return 0 if left.eos? && right.eos?
      return -1 if left.eos?
      return 1 if right.eos?

      numeric = left.peek(1).match?(/[0-9]/)
      pattern = numeric ? /[0-9]+/ : /[A-Za-z]+/
      left_segment = left.scan(pattern)
      right_segment = right.scan(pattern)
      return numeric ? 1 : -1 unless right_segment
      result = numeric ? left_segment.to_i <=> right_segment.to_i : left_segment <=> right_segment
      return result unless result.zero?
    end
  end
end
