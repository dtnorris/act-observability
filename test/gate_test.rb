# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require_relative "support/gate"

# Exercises the actual private runner on tiny disposable Ruby packages. These
# controls belong to the default suite; they never select a hidden population.
class GateTest < Minitest::Test
  # Yields an isolated package with measured one-line production coverage and
  # one real Minitest case; returns the block value. Filesystem errors propagate.
  def with_package
    Dir.mktmpdir("gate-contract-") do |root|
      FileUtils.mkdir_p(["#{root}/lib", "#{root}/test/support"])
      FileUtils.cp(Dir[File.join(__dir__, "support/*.rb")], "#{root}/test/support")
      File.write("#{root}/lib/fixture.rb", "module Fixture; VALUE = 1; end\n")
      File.write("#{root}/test/fixture_test.rb", <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/fixture"
        # Tiny package fixture; accepts no external inputs.
        class FixtureTest < Minitest::Test
          # Asserts the fixture constant; raises on a mismatch, returns an assertion.
          def test_value
            assert_equal 1, Fixture::VALUE
          end
        end
      RUBY
      File.write("#{root}/test/coverage_floors.json", JSON.generate("lib/fixture.rb" => {
        "line_percent" => 100, "branch_percent" => 100, "lines" => [1], "branches" => {} }))
      yield root
    end
  end

  # Runs one tiny package with a private shortened deadline. Returns exact
  # binary stdout/stderr and Process::Status; process-start errors propagate.
  def run_package(root, seconds: 3)
    driver = 'require_relative "test/support/gate"; exit BootstrapGate.run(Dir.pwd, deadline: BootstrapBudget.new(Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(ARGV.fetch(0))))'
    Open3.capture3({ "TMPDIR" => root }, RbConfig.ruby, "-e", driver, seconds.to_s, chdir: root, binmode: true)
  end

  # Extracts one real final result and its request binding from a passing fixture.
  # Yields both plus floors; malformed output/assertion errors propagate.
  def with_result
    with_package do |root|
      stdout, stderr, status = run_package(root)
      assert status.success?, stderr + stdout
      record = JSON.parse(stdout.lines.last)
      request = BootstrapGate.inventory(root).merge(record.slice("run", "source"))
      floors = JSON.parse(File.read("#{root}/test/coverage_floors.json"))
      yield record, request, floors
    end
  end

  # Proves recursive discovery by adding a nested failing test after a positive.
  # Assertion failures identify lost discovery, case accounting or diagnostics.
  def test_recursive_discovery_and_real_assertion_failure
    with_package do |root|
      assert run_package(root).last.success?
      FileUtils.mkdir_p("#{root}/test/nested")
      File.write("#{root}/test/nested/added_test.rb", <<~RUBY)
        # Added nested case used to prove recursive discovery.
        class AddedTest < Minitest::Test
          # Always raises an assertion failure; takes no arguments.
          def test_added_case
            flunk "nested case was discovered"
          end
        end
      RUBY
      stdout, stderr, status = run_package(root)
      assert_equal 1, status.exitstatus, stderr
      assert_includes stdout, "nested case was discovered"
      FileUtils.rm("#{root}/test/nested/added_test.rb")
      assert run_package(root).last.success?
    end
  end

  # Proves a successful raw exit cannot replace the required terminal document.
  def test_missing_child_result_fails_closed
    with_package do |root|
      original = File.read("#{root}/test/fixture_test.rb")
      File.write("#{root}/test/fixture_test.rb", "exit! 0\n")
      _, stderr, status = run_package(root)
      refute status.success?
      assert_includes stderr, "result.json"
      File.write("#{root}/test/fixture_test.rb", original)
      assert run_package(root).last.success?
    end
  end

  # Proves unloaded production cannot disappear from the coverage denominator.
  def test_unloaded_production_fails_closed
    with_package do |root|
      File.write("#{root}/lib/unloaded.rb", "module Unloaded; VALUE = 2; end\n")
      _, stderr, status = run_package(root)
      refute status.success?
      assert_includes stderr, "missing/unloaded production coverage"
      FileUtils.rm("#{root}/lib/unloaded.rb")
      assert run_package(root).last.success?
    end
  end

  # Proves text, binary bytes and nonstandard child exit status survive exactly.
  def test_child_status_and_binary_diagnostics_survive
    with_package do |root|
      File.write("#{root}/test/fixture_test.rb", <<~'RUBY')
        $stdout.sync = true
        $stdout.binmode.write("text\x00\xff".b)
        $stderr.write("child failed\n")
        exit! 23
      RUBY
      stdout, stderr, status = run_package(root)
      assert_equal 23, status.exitstatus
      assert_equal "text\x00\xff".b, stdout
      assert_equal "child failed\n", stderr
    end
  end

  # Proves stale/missing/corrupt coverage and partial accounting cannot pass,
  # using independently bound copies of a genuine successful fixture result.
  def test_invalid_evidence_is_rejected_and_restored_result_passes
    with_result do |record, request, floors|
      mutations = [
        ->(copy) { copy["run"] = "old-run" },
        ->(copy) { copy.delete("coverage") },
        ->(copy) { copy["coverage"]["lib/fixture.rb"]["lines"] = [-1] },
        ->(copy) { copy["coverage"]["lib/fixture.rb"]["lines"] = [0] },
        ->(copy) { copy["observed"] = [] },
        ->(copy) { copy["loaded"] = [] },
        ->(copy) { copy["counts"]["skips"] = 1 }
      ]
      mutations.each do |mutate|
        copy = JSON.parse(JSON.generate(record))
        mutate.call(copy)
        assert_raises(StandardError) { BootstrapGate.verify!(copy, request, floors) }
      end
      assert BootstrapGate.verify!(record, request, floors)
    end
  end

  # Proves complete line coverage cannot conceal an uncovered branch arm.
  def test_branch_floor_requires_every_measured_arm
    with_result do |record, request, floors|
      record["coverage"]["lib/fixture.rb"]["branches"] = { "decision" => { "yes" => 1, "no" => 0 } }
      floors["lib/fixture.rb"]["branches"] = { "decision" => %w[no yes] }
      error = assert_raises(RuntimeError) { BootstrapGate.verify!(record, request, floors) }
      assert_includes error.message, "branch coverage below floor"
      record["coverage"]["lib/fixture.rb"]["branches"]["decision"]["no"] = 1
      assert BootstrapGate.verify!(record, request, floors)
    end
  end

  # Proves private injected clocks reject an overrun without a ten-second sleep.
  def test_exhausted_budget_refuses
    budget = BootstrapBudget.new(10, clock: -> { 10 })
    assert_raises(RuntimeError) { budget.remaining! }
    assert_equal 0.25, BootstrapBudget.new(10, clock: -> { 9.75 }).remaining!
  end

  # Proves native process birth accounts for startup already consumed. This is
  # a clock capability check, not full public-invocation timing qualification.
  def test_native_budget_includes_process_startup
    remaining = BootstrapBudget.for_process.remaining!
    assert_operator remaining, :>, 0
    assert_operator remaining, :<, BootstrapBudget::LIMIT - BootstrapBudget::SHUTDOWN_RESERVE
  end

  # Proves a real hung child and its descendant are killed promptly by an
  # independent watchdog. Short fixture deadlines never alter the public cap.
  def test_real_watchdog_terminates_hung_process_group
    with_package do |root|
      File.write("#{root}/test/fixture_test.rb", "fork { sleep 60 }; sleep 60\n")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _, stderr, status = run_package(root, seconds: 0.2)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      refute status.success?
      assert_includes stderr, "budget exhausted"
      assert_operator elapsed, :<, 2
      File.write("#{root}/test/fixture_test.rb", <<~RUBY)
        require "minitest/autorun"
        require_relative "../lib/fixture"
        # Restored package fixture after deliberate process failure.
        class FixtureTest < Minitest::Test
          # Returns an assertion, raising on a mismatch; accepts no arguments.
          def test_restored
            assert_equal 1, Fixture::VALUE
          end
        end
      RUBY
      assert run_package(root).last.success?
    end
  end

  # Proves a full unread stderr pipe cannot delay termination of the gate parent
  # or worker group; an independent outer deadline bounds this regression itself.
  def test_watchdog_kills_parent_and_worker_when_stderr_is_full
    with_package do |root|
      marker = File.join(root, "processes.json")
      deadline_file = File.join(root, "watchdog-deadline.txt")
      File.write("#{root}/test/fixture_test.rb", <<~RUBY)
        marker = #{marker.to_json}
        File.write(marker, JSON.generate("worker" => Process.pid, "group" => Process.getpgrp, "parent" => Process.ppid))
        fork do
          loop { STDERR.write("x" * 65_536) }
        end
        sleep 60
      RUBY
      stderr_read, stderr_write = IO.pipe
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      runner = Process.spawn({ "TMPDIR" => root }, RbConfig.ruby, "-e",
        'require_relative "test/support/gate"; deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(ARGV.fetch(0)); File.write(ARGV.fetch(1), deadline.to_s); exit BootstrapGate.run(Dir.pwd, deadline: BootstrapBudget.new(deadline))',
        "0.35", deadline_file, chdir: root, out: File::NULL, err: stderr_write, pgroup: true)
      stderr_write.close
      runner_status = nil
      outer_deadline = started + 3
      begin
        loop do
          waited, runner_status = Process.waitpid2(runner, Process::WNOHANG)
          break if waited
          raise "independent outer timeout: runner=#{runner}, marker=#{File.exist?(marker)}, stderr_pipe_unread=true" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= outer_deadline

          sleep 0.01
        end
      rescue RuntimeError => error
        Process.kill("KILL", -runner) rescue nil
        Process.kill("KILL", runner) rescue nil
        if File.file?(marker)
          group = JSON.parse(File.read(marker)).fetch("group")
          Process.kill("KILL", -group) rescue nil
        end
        Process.wait(runner) rescue nil
        flunk error.message
      ensure
        stderr_read.close
      end

      terminated_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      elapsed = terminated_at - started
      assert File.file?(deadline_file), "runner did not record its independent watchdog deadline"
      deadline = Float(File.read(deadline_file))
      assert_operator terminated_at, :<=, deadline + 0.25, "watchdog termination missed its deadline: ended=#{terminated_at}, deadline=#{deadline}"
      assert runner_status&.signaled?, "watchdog did not terminate gate parent: #{runner_status.inspect}"
      assert_equal Signal.list.fetch("KILL"), runner_status.termsig
      assert_operator elapsed, :<, 1.5, "watchdog exceeded independent outer bound: #{elapsed.round(3)}s"
      assert File.file?(marker), "worker did not record process identities before blocking"
      identities = JSON.parse(File.read(marker))
      assert_equal runner, identities.fetch("parent")
      assert_equal identities.fetch("worker"), identities.fetch("group")
      residue_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      loop do
        parent_alive = process_alive?(runner)
        group_alive = process_group_alive?(identities.fetch("group"))
        break unless parent_alive || group_alive
        flunk "process residue after watchdog: parent=#{parent_alive}, group=#{group_alive}, identities=#{identities}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= residue_deadline

        sleep 0.01
      end
    end
  end

  # Checks whether a PID still exists; permission errors propagate as evidence.
  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # Checks whether any process remains in a process group; permission errors propagate.
  def process_group_alive?(group)
    Process.kill(0, -group)
    true
  rescue Errno::ESRCH
    false
  end
end
