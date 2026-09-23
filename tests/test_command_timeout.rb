# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "tempfile"

class CommandTimeoutTest < Minitest::Test
  RUNNER = File.expand_path("../scripts/run-command-with-timeout.rb", __dir__)

  def test_forwards_output_and_preserves_a_successful_exit
    Tempfile.create("command-timeout-log") do |log|
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        RUNNER,
        "--timeout-seconds", "5",
        "--log", log.path,
        "--",
        RbConfig.ruby, "-e", '$stdout.write("command-ok\\n")'
      )

      assert status.success?, stderr
      assert_equal "command-ok\n", stdout
      assert_equal "command-ok\n", File.read(log.path)
    end
  end

  def test_terminates_a_hung_process_group_with_timeout_status
    Tempfile.create("command-timeout-log") do |log|
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        RUNNER,
        "--timeout-seconds", "1",
        "--grace-seconds", "1",
        "--log", log.path,
        "--",
        RbConfig.ruby, "-e", "sleep 30"
      )
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      assert_equal 124, status.exitstatus
      assert_operator elapsed, :<, 5
      assert_includes stderr, "Command timed out after 1 seconds"
    end
  end
end
