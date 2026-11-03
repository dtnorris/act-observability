# frozen_string_literal: true

require "coverage"
require "json"
require "minitest"

# Observes real Minitest case results without parsing or trusting console text.
module BootstrapWorker
  # Records each case and genuine assertion/failure/error/skip counters.
  class Reporter < Minitest::StatisticsReporter
    attr_reader :cases

    # Initializes the case list; accepts no input and raises no extra exceptions.
    def initialize
      super
      @cases = []
    end

    # Records a Minitest result and its full name. Returns the underlying result;
    # malformed result exceptions propagate and prevent complete evidence.
    def record(result)
      @cases << "#{result.class_name}##{result.name}"
      super
    end
  end

  # Installs the private observer into Minitest's ordinary reporter pipeline.
  # Accepts Minitest options, returns the reporter array; plugin errors propagate.
  def self.minitest_plugin_init(_options)
    Minitest.reporter << REPORTER
  end

  REPORTER = Reporter.new
end

directory = ARGV.fetch(0)
# Set one explicit random seed before inspecting runnable_methods; Minitest uses
# it during discovery as well as execution. No selection arguments are accepted.
Minitest.seed = Random.rand(0x10000)
ARGV.replace(["--seed", Minitest.seed.to_s])
request = JSON.parse(File.read(File.join(directory, "request.json")))
expected_cases = []
case_files = []
Coverage.start(lines: true, branches: true)
# Registered first: runs after Minitest, its after_run hooks and test cleanup.
at_exit do
  coverage = Coverage.result.to_h.filter_map do |path, data|
    relative = path.delete_prefix(request.fetch("root") + "/")
    [relative, data] if request.fetch("production").include?(relative)
  end.to_h
  reporter = BootstrapWorker::REPORTER
  record = request.slice("run", "source").merge("loaded" => request.fetch("tests").select { |path| $LOADED_FEATURES.include?(File.join(request.fetch("root"), path)) },
    "expected" => expected_cases, "observed" => reporter.cases.sort, "case_files" => case_files,
    "counts" => { "tests" => reporter.count, "assertions" => reporter.assertions,
      "failures" => reporter.failures, "errors" => reporter.errors, "skips" => reporter.skips }, "coverage" => coverage)
  File.write(File.join(directory, "result.json"), JSON.generate(record))
end
Minitest.extensions << BootstrapWorker
require "minitest/autorun"
request.fetch("tests").each { |path| require File.join(request.fetch("root"), path) }
expected_cases = Minitest::Runnable.runnables.flat_map { |type| type.runnable_methods.map { |name| "#{type.name}##{name}" } }.sort
case_files = Minitest::Runnable.runnables.flat_map { |type| type.runnable_methods.map { |name| type.instance_method(name).source_location.first.delete_prefix(request.fetch("root") + "/") } }.uniq.sort
