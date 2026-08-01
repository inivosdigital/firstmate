# Agent memory ceiling verification

Audience: maintainer verification.

This record supports the current per-spawn memory ceiling guarantees in [`../configuration.md`](../configuration.md#agent-memory-ceiling-configspawn-memory-cap).
Operator behavior and the configuration schema stay in that guide.
Task chronology, incident narrative, and delivery transcripts stay in private task reports.

All measurements below were taken on 2026-08-01 on the aarch64 Orange Pi host: systemd 249 (249.11-0ubuntu3.21), 8 cores, `MemTotal` 16353860 kB, 8 GiB of zram swap, unprivileged user 1000.

## Host prerequisites

The ceiling needs a delegated cgroup v2 memory controller reachable from an unprivileged user session.
Four reads establish that, and `bin/fm-memcap.sh` re-establishes the same thing at every launch by probing rather than by inferring:

```sh
systemctl --user is-system-running                                  # running
stat -fc %T /sys/fs/cgroup                                          # cgroup2fs
cat /sys/fs/cgroup/user.slice/user-1000.slice/cgroup.controllers     # memory pids
systemd-run --user --scope -p MemoryMax=200M /bin/true               # Running scope as unit: run-....scope
```

No privileged step is involved in any of them.

## Scope placement and process shape

A transient user scope lands under the user manager, not under the caller's own cgroup:

```sh
$ cat /proc/self/cgroup
0::/user.slice/user-1000.slice/session-3.scope
$ systemd-run --user --scope --quiet -p MemoryMax=200M -- bash -c 'cat /proc/self/cgroup'
0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-r1fce....scope
```

Two properties follow, and both are load-bearing.
Scopes do not nest inside the caller, so a secondmate's own crewmates are capped as siblings rather than counted against the secondmate's ceiling.
And `systemd-run --scope` execs rather than forks, so the wrapped agent adds no process layer and keeps the pane's tty:

```sh
$ systemd-run --user --scope --quiet -p MemoryMax=100M -- sleep 20 &
$ pstree -p $$
bash(916302)-+-bash(916304)---sleep(916306)
```

Environment set in front of the wrapper reaches the wrapped command (`FOO=bar systemd-run --user --scope ... -- bash -c 'echo $FOO'` prints `bar`), which is what lets `bin/fm-memcap.sh` re-export a launch command's own environment prefix.

## Why MemoryMax alone, and not MemoryHigh

`MemoryHigh` reads like free back-pressure, so the measurement below is the reason it is not set.

The same runaway (a Python process appending 1 MiB `bytearray`s) was run twice against a 200M ceiling.
With `MemoryHigh=160M` alongside `MemoryMax=200M` and `MemorySwapMax=0`, it did not die.
It parked in uninterruptible sleep and crawled:

```sh
$ cat .../run-r7d18e9d....scope/memory.current   # 177516544
$ sleep 30; cat .../memory.current              # 178028544   -> ~500 KiB / 30 s
$ cat .../memory.events
high 28517
max 0
oom_kill 0
$ grep ^pgscan .../memory.stat                   # pgscan 0  (nothing reclaimable)
$ ps -o stat,pcpu -p <pid>                       # D  0.6
```

At roughly 1 MiB/min, a `MemoryHigh` set a fifth under the shipped 40% ship ceiling would leave about 1.3 GiB to cross on this host, on the order of a full day of a hung agent.
The cause is structural rather than tuning: an agent's growth is almost entirely anonymous memory, `MemorySwapMax=0` leaves it unreclaimable, and `MemoryHigh` therefore throttles against nothing.

With `MemoryMax=200M -p MemorySwapMax=0` and no `MemoryHigh`, the identical runaway died in one second with exit 137.
A ceiling exists to end a stall, so the variant that introduces a slower stall is not shipped.

## Containment is targeted

An 8 GiB runaway - the scale of the agents in this host's kernel log - inside a 1G ceiling, with a 500 MiB witness process running outside the scope:

```
witness pid=1013476 rss=521244KB
runaway exit=137
witness still alive immediately after the kill
witness result: WITNESS SURVIVED
system oom_kill counter: before=2 after=3
```

```
[43569.895269] Memory cgroup out of memory: Killed process 1013501 (python3)
  total-vm:1062204kB, anon-rss:1046288kB, file-rss:5068kB, UID:1000
```

The kill was the cgroup OOM killer, not the global one; it landed at the ceiling; the system-wide counter moved by exactly one; and available memory (8519 MB before, 8512 MB after) and load average were unchanged.
This is the property a machine-wide killer cannot offer, since that picks the largest process on the box and may well pick a production service.

That `Memory cgroup out of memory` line is also the only place a ceiling kill is distinguishable from an ordinary agent crash.
The scope contains the agent alone - the pane's shell is its parent and stays outside it - so the pane survives the kill.
Observed in a real pane after a 128M ceiling was exceeded:

```
$ tmux list-panes -F '#{pane_id} dead=#{pane_dead} pid=#{pane_pid}'
%0 dead=0 pid=1227235
$ tmux capture-pane -p | tail -2
Killed
bash-5.1$
```

The endpoint is alive and idle, which is the same picture firstmate gets from any agent that exited, so recovery treats it as a stopped worker rather than a dead endpoint.
The pane's `Killed` line is the shell reporting SIGKILL and says nothing about which killer sent it.
`dmesg` is readable unprivileged on this host (`kernel.dmesg_restrict` is `0`), so the distinction is available on demand; nothing surfaces it automatically, and nothing here adds a reporting path for it.

## End-to-end through the real spawn path

Driven through the real `bin/fm-spawn.sh` into a real tmux server, with the ceiling read back from the launched process's own cgroup rather than from the command meant to set it.

With `config/spawn-memory-cap` holding `2G`:

```
spawned memcap-proof harness=claude kind=ship ... worktree=.../pool-abc123/1/proj
meta: memcap=2G
agent pid=1038983 args=sleep 900
/proc/1038983/cgroup  -> /user.slice/user-1000.slice/user@1000.service/app.slice/run-r6ee....scope
memory.max            = 2147483648
memory.swap.max       = 0
memory.high           = max
scope Description     = firstmate memcap-proof
pane shell cgroup     = /user.slice/user-1000.slice/session-3.scope
```

With no config file at all, the ship default resolved and applied: `meta: memcap=40%`, `memory.max = 6698541056`, which is 40% of this host's 16746352640-byte `MemTotal`.

With `systemd-run` made to fail inside the pane, the spawn still succeeded and the agent still ran, uncapped and unhidden:

```
spawned memcap-proof harness=claude kind=ship ...
agent pid=1043955 args=sleep 900
/proc/1043955/cgroup -> /user.slice/user-1000.slice/session-3.scope   (the pane's own cgroup)
memory.max           = max
pane: fm-memcap: no usable systemd user scope here; launching without a memory ceiling
```

`tests/fm-memcap.test.sh` is the reusable regression for all of the above.
Its two real-scope cases self-skip on a host that cannot create user scopes, so the suite stays portable.
