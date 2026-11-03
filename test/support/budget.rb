# frozen_string_literal: true

require "fiddle"

# Private default-gate deadline, including the current Mac process's startup.
class BootstrapBudget
  LIMIT = 10.0
  SHUTDOWN_RESERVE = 0.25

  # Accepts a monotonic deadline and optional private test clock. Returns a
  # budget; clock errors propagate. No environment setting changes the limit.
  def initialize(deadline, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @deadline, @clock = deadline, clock
  end

  # Returns remaining seconds, raising RuntimeError when the budget is exhausted.
  def remaining!
    remaining = @deadline - @clock.call
    raise "ten-second complete-run budget exhausted" unless remaining.positive?

    remaining
  end

  # Returns a budget debited by kernel process age on the qualified Darwin ABI.
  # rusage_info_v0 has a 16-byte UUID then eight uint64 fields before process
  # birth at offset 80. mach_absolute_time uses the same native tick clock.
  # Unsupported hosts/APIs fail closed; package imports themselves are portable.
  def self.for_process
    raise "default gate requires a qualified Darwin host" unless RUBY_PLATFORM.include?("darwin")

    usage = Fiddle::Pointer.malloc(96)
    timebase = Fiddle::Pointer.malloc(8)
    status = native("proc_pid_rusage", [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT).call(Process.pid, 0, usage)
    conversion = native("mach_timebase_info", [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT).call(timebase)
    raise "kernel process-start clock unavailable" unless status.zero? && conversion.zero?

    numerator, denominator = timebase[0, 8].unpack("L2")
    birth = usage[80, 8].unpack1("Q")
    ticks = native("mach_absolute_time", [], Fiddle::TYPE_LONG_LONG).call
    raise "invalid kernel process-start clock" unless birth.positive? && ticks >= birth && denominator.positive?

    age = (ticks - birth) * numerator.fdiv(denominator) / 1_000_000_000
    now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    new(now + LIMIT - SHUTDOWN_RESERVE - age)
  end

  # Builds one native self-process clock call. Missing symbols raise Fiddle errors.
  def self.native(name, arguments, result)
    Fiddle::Function.new(Fiddle::Handle::DEFAULT[name], arguments, result)
  end

  # Starts an independent watchdog for the test process group and this parent.
  # Returns its PID; fork/clock errors propagate. SIGKILL bounds hung reporting
  # and descendants even if the parent thread cannot service a Ruby timeout.
  def watch(group)
    remaining!
    parent = Process.pid
    fork do
      sleep [@deadline - @clock.call, 0].max
      terminate(-group)
      terminate(parent)
      begin
        $stderr.write_nonblock("ten-second complete-run budget exhausted; terminating test process group\n", exception: false)
      rescue StandardError
        nil
      end
      exit! 124
    end
  end

  # Kills a process or group if it still exists. Returns nil; other OS errors
  # propagate, so cleanup failure cannot silently become a successful gate.
  def terminate(identifier)
    Process.kill("KILL", identifier)
    nil
  rescue Errno::ESRCH
    nil
  end

  # Stops and reaps this budget's watchdog. Returns nil; wait errors propagate.
  def stop(watcher)
    terminate(watcher)
    Process.wait(watcher)
    nil
  end
end
