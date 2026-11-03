# frozen_string_literal: true

require "bundler/setup"
require_relative "test/support/budget"
require_relative "test/support/gate"

# Kernel process age includes Ruby, Bundler and Rake startup before this file.
deadline = BootstrapBudget.for_process
desc "Run every test with fresh production coverage inside ten seconds"
task :default do
  exit BootstrapGate.run(__dir__, deadline: deadline)
end
