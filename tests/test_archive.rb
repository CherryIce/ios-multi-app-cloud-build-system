# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rubygems/package"
require "tmpdir"
require "zlib"

class ArchiveTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  VALIDATOR = File.join(ROOT, "scripts/validate-profiles-archive.rb")

  def test_safe_profile_archive_is_accepted
    with_archive("profiles/App.mobileprovision") do |archive|
      _stdout, stderr, status = Open3.capture3("ruby", VALIDATOR, archive)
      assert status.success?, stderr
    end
  end

  def test_path_traversal_is_rejected
    with_archive("../App.mobileprovision") do |archive|
      _stdout, _stderr, status = Open3.capture3("ruby", VALIDATOR, archive)
      refute status.success?
    end
  end

  private

  def with_archive(entry_name)
    Dir.mktmpdir do |directory|
      path = File.join(directory, "profiles.tar.gz")
      Zlib::GzipWriter.open(path) do |gzip|
        Gem::Package::TarWriter.new(gzip) do |tar|
          content = "not-a-real-profile"
          tar.add_file_simple(entry_name, 0o600, content.bytesize) { |file| file.write(content) }
        end
      end
      yield path
    end
  end
end
