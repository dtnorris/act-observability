# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "rbconfig"
require_relative "../lib/act_observability"
require "stringio"

# Exercises the byte-safe capture seam without a command fake masking bytes.
class GateCaptureTest < Minitest::Test
  # Runs one finite real Ruby child; capture preserves the native boolean/status
  # and both binary streams without importing main or supplying command policy.
  def test_real_command_failure_and_binary_streams
    Dir.mktmpdir do |directory|
      out, err = StringIO.new("".b), StringIO.new("".b)
      capture = ActObservability::GateCapture.new(directory, "child", out: out, err: err)
      result = capture.run do |pipes|
        system(RbConfig.ruby, File.join(__dir__, "support/fixtures/capture_command.rb"), **pipes)
      end
      assert_equal false, result
      assert_equal 7, $?.exitstatus
      assert_equal "out\x00\xff".b, out.string
      assert_equal "err\x80".b, err.string
      assert_equal "complete", capture.result["status"]
    end
  end

  # Directory fsync failure is reported even after content hashing succeeds;
  # the digest describes bytes and does not certify durable directory entries.
  def test_directory_sync_failure_is_not_complete
    Dir.mktmpdir do |directory|
      original_open = File.method(:open)
      opener = lambda do |path, *arguments, &block|
        raise Errno::EIO, "directory sync" if path == directory
        original_open.call(path, *arguments, &block)
      end
      capture = ActObservability::GateCapture.new(directory, "directory", out: StringIO.new, err: StringIO.new)
      File.stub(:open, opener) { assert_equal :ran, capture.run { |pipes| pipes[:out].write("data"); :ran } }
      assert_equal "incomplete", capture.result["status"]
      capture.result.fetch("streams").each_value do |stream|
        assert_equal "persistence_error", stream["status"]
        assert stream.key?("sha256")
      end
    end
  end

  # Empty output is durable and binary stderr retains its own counts and digest.
  # Real private files must retain their exact bytes and restrictive modes.
  def test_complete_streams_and_private_files
    Dir.mktmpdir do |directory|
      out, err = StringIO.new("".b), StringIO.new("".b)
      capture = ActObservability::GateCapture.new(directory, "private", out: out, err: err)
      assert_equal false, capture.run { |pipes| pipes[:err].write("\x80\x00\xff".b); false }
      assert_equal "complete", capture.result["status"]
      { "stdout" => "".b, "stderr" => "\x80\x00\xff".b }.each do |name, bytes|
        stream = capture.result.fetch("streams").fetch(name)
        path = File.join(directory, stream.fetch("file"))
        assert_equal bytes, File.binread(path)
        assert_equal bytes.bytesize, stream.fetch("bytes")
        assert_equal bytes.bytesize, stream.fetch("observed_bytes")
        assert_equal Digest::SHA256.hexdigest(bytes), stream.fetch("sha256")
        assert_equal 0o600, File.stat(path).mode & 0o777
      end
      assert_empty out.string
      assert_equal "\x80\x00\xff".b, err.string
    end
  end

  # Existing files and symlinks are never replaced or followed. Missing storage
  # still drains and forwards both real streams without claiming persistence.
  def test_storage_refusals_preserve_existing_bytes
    Dir.mktmpdir do |directory|
      target = File.join(directory, "target")
      File.binwrite(target, "untouched")
      File.symlink(target, File.join(directory, "gate-collision.stdout"))
      File.binwrite(File.join(directory, "gate-collision.stderr"), "existing")
      [directory, File.join(directory, "missing")].each do |storage|
        out, err = StringIO.new("".b), StringIO.new("".b)
        capture = ActObservability::GateCapture.new(storage, "collision", out: out, err: err)
        assert_equal :ran, capture.run { |pipes| pipes[:out].write("a"); pipes[:err].write("b"); :ran }
        capture.result.fetch("streams").each_value do |stream|
          assert_equal "persistence_error", stream["status"]
          assert_equal 0, stream["bytes"]
          assert_equal 1, stream["observed_bytes"]
          refute stream.key?("sha256")
        end
        assert_equal "a", out.string
        assert_equal "b", err.string
      end
      assert_equal "untouched", File.binread(target)
      assert_equal "existing", File.binread(File.join(directory, "gate-collision.stderr"))
      assert File.symlink?(File.join(directory, "gate-collision.stdout"))
    end
  end

  # Injects one durable-file operation failure on a real stdout file. All other
  # I/O remains real; write/flush/fsync/close errors cannot replace command errors.
  def test_durable_failures_preserve_original_exception_and_console
    %i[write flush fsync close].each do |operation|
      Dir.mktmpdir do |directory|
        original_open = File.method(:open)
        injected = false
        close_calls = 0
        opener = lambda do |path, *arguments, &block|
          file = original_open.call(path, *arguments, &block)
          if path == File.join(directory, "gate-fault.stdout")
            original_operation = file.method(operation)
            file.define_singleton_method(operation) do |*values|
              if operation == :close
                close_calls += 1
                original_operation.call(*values) if close_calls == 2
                injected = true
                raise IOError, "injected close"
              end
              unless injected
                injected = true
                raise IOError, "injected #{operation}"
              end
              original_operation.call(*values)
            end
          end
          file
        end
        out = StringIO.new("".b)
        capture = ActObservability::GateCapture.new(directory, "fault", out: out, err: StringIO.new)
        failure = RuntimeError.new("command failed")
        File.stub(:open, opener) do
          assert_same failure, assert_raises(RuntimeError) {
            capture.run { |pipes| pipes[:out].write("\xff".b); raise failure }
          }
        end
        assert injected, "fault did not reach #{operation}"
        assert_equal "persistence_error", capture.result.dig("streams", "stdout", "status")
        assert_equal "complete", capture.result.dig("streams", "stdout", "console")
        assert_equal "complete", capture.result.dig("streams", "stderr", "status")
        assert_equal 1, capture.result.dig("streams", "stdout", "observed_bytes")
        assert_equal "\xff".b, out.string
      end
    end
  end

  # A console flush error is independent of complete durable byte capture.
  def test_console_failure_does_not_change_durable_capture
    Dir.mktmpdir do |directory|
      console = StringIO.new("".b)
      console.define_singleton_method(:flush) { raise IOError, "console flush" }
      delivered = "".b
      write_only = Object.new
      write_only.define_singleton_method(:write) { |bytes| delivered << bytes }
      capture = ActObservability::GateCapture.new(directory, "console", out: console, err: write_only)
      capture.run do |pipes|
        pipes[:out].write("\xff".b * 32_769)
        pipes[:err].write("write only")
      end
      assert_equal "complete", capture.result["status"]
      assert_equal "delivery_error", capture.result.dig("streams", "stdout", "console")
      assert_equal "complete", capture.result.dig("streams", "stderr", "console")
      assert_equal "\xff".b * 32_769, File.binread(File.join(directory, "gate-console.stdout"))
      assert_equal "write only", delivered
    end
  end

  # Caller-closed redirections are still drained without a double-close error.
  def test_caller_closed_writers_are_safe
    Dir.mktmpdir do |directory|
      capture = ActObservability::GateCapture.new(directory, "closed", out: StringIO.new, err: StringIO.new)
      assert_nil capture.run { |pipes| pipes.each_value(&:close); nil }
      assert_equal "complete", capture.result["status"]
    end
  end

  # A still-open inherited pipe is killed and drained within bounded cleanup.
  # Partial evidence remains incomplete and no capture thread survives the call.
  def test_inherited_pipe_cleanup_is_bounded_and_truthful
    Dir.mktmpdir do |directory|
      capture = ActObservability::GateCapture.new(directory, "partial", out: StringIO.new, err: StringIO.new)
      inherited = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_equal :result, capture.run { |pipes| inherited = pipes[:out].dup; pipes[:out].write("partial"); :result }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
      assert_equal "incomplete", capture.result["status"]
      assert_equal "incomplete", capture.result.dig("streams", "stdout", "status")
      assert_equal 7, capture.result.dig("streams", "stdout", "bytes")
      assert_equal "partial", File.binread(File.join(directory, "gate-partial.stdout"))
      assert capture.instance_variable_get(:@threads).none?(&:alive?)
    ensure
      inherited&.close
    end
  end

  # Both streams preserve binary/partial writes, empty output and explicit caps.
  # Only bounded test strings are allocated; the console oracle sees all bytes.
  def test_binary_streams_empty_output_and_output_limit
    Dir.mktmpdir do |directory|
      out, err = StringIO.new("".b), StringIO.new("".b)
      capture = ActObservability::GateCapture.new(directory, "fixture", out: out, err: err)
      chunk = "\x00\xff".b * 8192
      assert_equal :command_result, capture.run { |pipes|
        257.times { pipes[:out].write(chunk); pipes[:err].write(chunk.reverse) }
        :command_result
      }
      result = capture.result
      assert_equal "incomplete", result["status"]
      { "stdout" => [chunk, out], "stderr" => [chunk.reverse, err] }.each do |name, (stream_chunk, console)|
        stream = result.fetch("streams").fetch(name)
        assert_equal "truncated", stream["status"]
        assert_equal stream_chunk.bytesize * 257, stream["observed_bytes"]
        assert_equal ActObservability::GateCapture::LIMIT, stream["bytes"]
        assert_equal stream_chunk * 257, console.string
        retained = stream_chunk * 256
        assert_equal retained, File.binread(File.join(directory, stream["file"]))
        assert_equal Digest::SHA256.hexdigest(retained), stream["sha256"]
      end
    end
  end

  # Missing storage/console failures never become command success; exceptions
  # remain the original objects and retained counts explicitly describe loss.
  def test_persistence_console_and_command_failures_are_independent
    broken = Object.new
    broken.define_singleton_method(:write) { |_| raise IOError }
    capture = ActObservability::GateCapture.new(nil, "fixture", out: broken, err: StringIO.new)
    failure = Interrupt.new("fixture interruption")
    actual = assert_raises(Interrupt) { capture.run { |pipes| pipes[:out].write("\x80".b); raise failure } }
    assert_same failure, actual
    assert_equal "incomplete", capture.result["status"]
    assert_equal "persistence_error", capture.result.dig("streams", "stdout", "status")
    assert_equal "delivery_error", capture.result.dig("streams", "stdout", "console")
    assert_equal 1, capture.result.dig("streams", "stdout", "observed_bytes")
  end
end
