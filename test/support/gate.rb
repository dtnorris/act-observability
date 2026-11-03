# frozen_string_literal: true

require "digest"
require "json"
require "rbconfig"
require "securerandom"
require "tmpdir"
require_relative "budget"

# Private single-suite orchestration; never a production coverage denominator.
module BootstrapGate
  # Returns recursively discovered test/production paths. Missing populations
  # raise; all future production bin/exe files join the inventory, without an
  # extension filter. Helpers remain under test/support rather than bin.
  def self.inventory(root)
    tests = Dir.chdir(root) { Dir["test/**/*_test.rb"].sort }
    production = Dir.chdir(root) { Dir["lib/**/*.rb", "bin/**/*", "exe/**/*"].select { |path| File.file?(path) }.sort }
    raise "empty test or production inventory" if tests.empty? || production.empty?

    { "tests" => tests, "production" => production }
  end

  # Binds inventories and source bytes for this invocation. Returns a digest;
  # filesystem errors propagate, including newly missing files.
  def self.fingerprint(root, inventory)
    paths = (inventory.values.flatten + Dir.chdir(root) { Dir["test/support/**/*", "test/*.json", "Gemfile*", "*.gemspec", "Rakefile"].select { |path| File.file?(path) } }).uniq.sort
    Digest::SHA256.hexdigest(JSON.generate(paths.to_h { |path| [path, Digest::SHA256.file(File.join(root, path)).hexdigest] }))
  end

  # Runs the sole test child with a fresh private result channel. Returns the
  # genuine child exit code (128+signal), or 1 for invalid evidence. Child bytes
  # inherit the real stdout/stderr streams, preserving binary diagnostics. All
  # source, cleanup, reporting and verification work consumes the same budget.
  def self.run(root, deadline:)
    root = File.realpath(root)
    selected = inventory(root)
    digest = fingerprint(root, selected)
    identity = SecureRandom.hex(16)
    result = nil
    record = nil
    Dir.mktmpdir("bootstrap-gate-") do |directory|
      request = selected.merge("root" => root, "source" => digest, "run" => identity)
      File.write(File.join(directory, "request.json"), JSON.generate(request))
      deadline.remaining!
      child = Process.spawn({ "MT_NO_PLUGINS" => "1", "MT_CPU" => "1" }, RbConfig.ruby,
        File.join(root, "test/support/worker.rb"), directory, chdir: root, pgroup: true)
      begin
        watcher = deadline.watch(child)
        _, status = Process.wait2(child)
        result = status.exitstatus || 128 + status.termsig
        raise "source inventory changed during gate" unless inventory(root) == selected && fingerprint(root, selected) == digest

        # A reaped worker must leave no running descendants in its process group.
        begin
          Process.kill(0, -child)
          raise "test subprocess left unfinished descendants"
        rescue Errno::ESRCH
          nil
        end
        if result.zero?
          record = JSON.parse(File.binread(File.join(directory, "result.json")))
          verify!(record, request, JSON.parse(File.read(File.join(root, "test/coverage_floors.json"))))
        end
      ensure
        deadline.terminate(-child)
        # Keep the watchdog active during temporary-file cleanup and reporting.
        at_exit { deadline.stop(watcher) } if watcher
      end
    end
    remaining = deadline.remaining!
    if record
      record.fetch("coverage").each do |path, data|
        lines = data.fetch("lines").compact
        branches = data.fetch("branches").values.flat_map(&:values)
        puts "#{path}: lines #{lines.count(&:positive?)}/#{lines.size}; branch arms #{branches.count(&:positive?)}/#{branches.size}"
      end
      record["budget_remaining_seconds"] = remaining
      record["shutdown_reserve_seconds"] = BootstrapBudget::SHUTDOWN_RESERVE
      puts JSON.generate(record)
    end
    deadline.remaining!
    result
  rescue StandardError => error
    warn "default gate: #{error.class}: #{error.message}"
    1
  end

  # Validates this invocation's terminal accounting and per-file coverage. Returns
  # true or raises for missing/stale/corrupt results, omitted cases/files, skips,
  # changed node inventories or coverage below the committed measured floors.
  def self.verify!(record, request, floors)
    raise "stale or mismatched child result" unless record.values_at("run", "source") == request.values_at("run", "source")
    raise "undiscovered test files" unless record["loaded"] == request.fetch("tests")
    raise "test file defines no cases" unless record["case_files"] == request.fetch("tests")

    expected, observed = record.values_at("expected", "observed")
    raise "incomplete test cases" unless expected.is_a?(Array) && !expected.empty? && expected.uniq == expected && observed == expected
    counts = record.fetch("counts")
    raise "invalid test counters" unless counts.keys.sort == %w[assertions errors failures skips tests] && counts.values.all? { |count| count.is_a?(Integer) && count >= 0 }
    raise "failed, skipped or empty test cases" unless counts.values_at("errors", "failures", "skips") == [0, 0, 0] && counts["tests"] == expected.size && counts["assertions"].positive?

    coverage = record.fetch("coverage")
    raise "missing/unloaded production coverage or floors" unless coverage.keys.sort == request.fetch("production") && floors.keys.sort == request.fetch("production")
    coverage.each do |path, data|
      floor = floors.fetch(path)
      lines = data.fetch("lines")
      branches = data.fetch("branches").values.flat_map(&:values)
      raise "corrupt coverage: #{path}" unless lines.is_a?(Array) && lines.all? { |hit| hit.nil? || hit.is_a?(Integer) && hit >= 0 } && branches.all? { |hit| hit.is_a?(Integer) && hit >= 0 }
      nodes = lines.each_index.select { |index| !lines[index].nil? }.map { |index| index + 1 }
      branch_nodes = data.fetch("branches").transform_values { |arms| arms.keys.sort }
      raise "unmeasured coverage nodes: #{path}" unless !nodes.empty? && nodes == floor.fetch("lines") && branch_nodes == floor.fetch("branches")
      raise "line coverage below floor: #{path}" if 100.0 * lines.compact.count(&:positive?) / nodes.size < floor.fetch("line_percent")
      raise "branch coverage below floor: #{path}" if !branches.empty? && 100.0 * branches.count(&:positive?) / branches.size < floor.fetch("branch_percent")
    end
    true
  end
end
