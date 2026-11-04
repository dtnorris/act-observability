# act-observability

An independently installable Ruby package with the `ActObservability` namespace.
The package owns bounded binary `GateCapture`; main ACT owns command execution,
checkpoint policy and receipt interpretation. This is the M2 seed in the authoritative
[breakup plan](https://github.com/dtnorris/agent-coding-tool-data/blob/007deb1093e58c2848cfa99b3477965351736fb3/plans/ab/AB-PLN-01A/plan.md).

```ruby
require "act_observability"
ActObservability::VERSION # => "0.1.0"
```

The gem has no runtime gem dependencies, imports no other ACT repository, and
does not read `.env`. Main ACT retains command and mode-selection authority.
Publication, exact dependency refs, installed-ACT adoption and successor
preparation require operator review. AB-OB-01B qualifies only this package;
AB-OB-01C owns main adoption against the accepted operator-published package
revision and digest. No accepted split composition is declared here.

Install development dependencies with `bundle install` (separate from test
timing). Both `rake` and `bundle exec rake` run the **same entire default suite**,
with recursive `test/**/*_test.rb` discovery, genuine Minitest accounting, no
skips or selection flags, and fresh line/branch coverage of every production
file. Test-only helpers live under `test/support`; future `bin/` and `exe/`
production files join the coverage inventory. Unloaded files, unmeasured nodes,
missing/stale/corrupt results and unfinished descendants fail the gate. Coverage
hits never carry across runs. Each test file must define at least one case.

`test/coverage_floors.json` records the measured bootstrap executable nodes and
100% line/branch floors; files without branches report an empty branch inventory.
This measures the import/version contract, not domain behavior. Migrated sources
require their original measured floors and covered-node mapping before adoption.

`GateCapture.new(directory, token, out:, err:).run` yields native pipe
redirections and returns the caller's value or raises its original exception.
`result` reports per-stream observed/retained byte counts, SHA-256, truncation,
durable-file failure and console delivery independently. Private exclusive files,
flush/fsync and bounded inherited-pipe cleanup retain the main seed's contract.
The package supplies no command authorization, task interpretation, receipts,
sharing, tunnel or recovery policy. Main's legacy default, compatibility adapter
and continuous public gate journey remain AB-OB-01C responsibilities.

`test/gate_capture_reference.json` binds the original main source and guarded
focused measurement. `test/coverage_floors.json` preserves every mapped covered
node and ratchets its numeric floors using the expanded package cases. The only
remaining uncovered arm is the defensive already-closed reader check: the
capture owns that reader and closes it only in its drain ensure block.

The initial timing contract targets David's Darwin arm64 Mac with Ruby 4.0.6
and this lockfile. The private watchdog supervises test startup through cleanup,
coverage verification and reporting. Native `proc_pid_rusage` and
`mach_absolute_time` debit Ruby/Bundler/Rake process startup from ten seconds;
0.25 seconds is reserved for process shutdown and launcher overhead. The
independent watchdog kills the parent and the test process group on exhaustion.
Unsupported clock APIs fail closed; package imports remain independent of the
test host. No environment variable changes the cap or disables coverage.

Kernel process age cannot observe time spent in a preceding shell/tool shim.
The operator must qualify the **outer launch-to-exit** time for both ordinary
commands on the named host, including those launchers, within ten seconds and
confirm the 0.25-second reserve covers their gap. A private runner measurement
alone is insufficient. Host checkpoint-gated measurements remain distinct from
focused worker checks; a new launcher/runtime/host requires requalification.
The successful final JSON reports remaining budget after temporary-file cleanup.
For an ordinary invocation, `10 - 0.25 - budget_remaining_seconds` is native
process age at that observation; compare outer elapsed time against it to
qualify the launcher/shutdown gap. Fixture deadlines are private fault controls
and do not supply host timing evidence.

Contributions follow the canonical
[coding](https://github.com/dtnorris/agent-skills/blob/8ac096dd81865ea9e30ef84c6a8127db68e159bb/skills/karpathy-manning-dtnorris-guidelines/SKILL.md)
and [planning](https://github.com/dtnorris/agent-skills/blob/8ac096dd81865ea9e30ef84c6a8127db68e159bb/skills/agentic-task-planning/SKILL.md)
guidance, subject to task-specific authority. This README describes the package
and its bootstrap developer contract; the cross-repository plan remains the
architectural authority.
