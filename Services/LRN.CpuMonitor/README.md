# LRN CPU Monitor

A Windows service that watches every process and logs the ones sustaining high CPU,
together with enough detail to work out what caused it.

For each breach it records the application name, full executable path, PID, owner,
session, command line and the parent-process chain that launched it.

## How CPU is measured

Processor time is read twice and the delta divided by elapsed wall-clock time.
Performance counters are deliberately not used: the `Process` counter category
identifies processes by an ambiguous `name#index`, which collides whenever several
share a name — exactly the case here for `w3wp`, `dotnet` and `EXCEL`.

`NormalizeByCoreCount` decides the scale, and it matters more than the threshold:

| Setting | 100% means | Use when |
| --- | --- | --- |
| `true` (default) | every core saturated, as Task Manager's CPU column reports | you care about the box being consumed |
| `false` | one core saturated; the value can reach 100 × core count | you care about a single runaway thread |

On an 8-core server a single-threaded runaway loop only reads about 12% normalized,
so it will never trip a 90% threshold. If you want to catch one hot thread, either
set `NormalizeByCoreCount` to `false` and keep the threshold at 90, or keep
normalizing and lower the threshold to roughly `90 / core count`.

By default a process is logged on the first window it goes over the threshold, and
again on every window it stays over, so the log shows how long it lasted. Raising
`ConsecutiveSamplesBeforeAlert` requires that many back-to-back windows before
anything is written, and `AlertCooldownMinutes` suppresses repeats per PID. Both
reduce noise, but be aware of what they cost: with three consecutive windows and a
five-second window plus a ten-second poll gap, a process has to stay hot for about
thirty-five continuous seconds before it appears at all.

### The machine-total rule

A per-process threshold cannot catch a machine that is busy because load is spread
across many processes, which is the common case. Measured on an eight-core box at
64% total CPU, the four busiest processes were at 10-11% each: no per-process
threshold set anywhere sensible would have fired. `MachineCpuThresholdPercent`
covers that case by logging the top `MachineTopConsumers` processes together,
with full path, command line, owner and parent chain for each, whenever the
machine total goes over.

## Configuration

All keys live under `CpuMonitorSettings` in `appsettings.json` and are re-read
without a restart. Any key can be overridden by environment variable using the
double-underscore form, for example `CpuMonitorSettings__CpuThresholdPercent=75`.

| Key | Default | Purpose |
| --- | --- | --- |
| `Enabled` | `true` | Master switch |
| `CpuThresholdPercent` | `40` | Per-process breach threshold |
| `NormalizeByCoreCount` | `true` | Scale, see above |
| `MachineCpuThresholdPercent` | `85` | Machine-total threshold; `0` disables |
| `MachineTopConsumers` | `5` | Processes named in a machine-total alert |
| `SampleWindowSeconds` | `5` | Measurement window |
| `PollIntervalSeconds` | `10` | Gap between windows |
| `ConsecutiveSamplesBeforeAlert` | `1` | Windows required before alerting |
| `AlertCooldownMinutes` | `0` | Repeat-alert suppression per PID; `0` logs every window |
| `HeartbeatMinutes` | `10` | Proof-of-life line; `0` disables |
| `IgnoreProcessNames` | Idle, System, Memory Compression | Never reported |
| `BreachLogPath` | `Logs\cpu-breaches.jsonl` | Machine-readable log; blank disables |
| `SqlProcessNames` | `sqlservr` | Triggers the SQL attribution probe |
| `SqlConnectionString` | empty | Needed for the SQL probe; blank disables it |
| `SqlTopSessions` | `5` | Requests to report |
| `OfficeProcessNames` | EXCEL, WINWORD, ... | Triggers the Office launch probe |

## Logs

Three files, all under `Logs\`:

| File | Contents | Retained |
| --- | --- | --- |
| `cpu-breaches-<date>.txt` | **Threshold breaches only**, including the SQL and Office attribution lines | 180 days |
| `cpu-monitor-<date>.txt` | Everything, so a breach can be read in the context of the cycles around it | 30 days |
| `cpu-breaches.jsonl` | One JSON object per breach, for querying without parsing prose | until removed |

The breach file is kept far longer than the operational log because it is the record
you come back to weeks later asking what was eating the box.

## Working out what triggered a breach

The honest answer differs sharply by process type.

### SQL Server — yes, precisely

`sqlservr.exe` runs every database, session and query inside one process, so
process-level CPU says nothing about the cause. When a configured SQL process
breaches, the monitor queries `sys.dm_exec_requests` joined to
`sys.dm_exec_sessions` and reports the top CPU consumers with:

- `program_name` — the client application name
- `host_name` and `host_process_id` — **the caller's machine and PID**, which is the
  most direct answer available
- `login_name`, database, wait type, blocking session and the running statement

Two prerequisites:

1. The monitor's login needs `VIEW SERVER STATE`. Prefer `Integrated Security=True`
   in `SqlConnectionString` so no password is stored in config.
2. **Set `Application Name` in every service's connection string.** Without it every
   caller reports as `.Net SqlClient Data Provider` and `program_name` is useless.
   This is a one-line change per service and it is what makes the difference between
   "some .NET app" and "LRN.ReportWorker".

### Excel and other Office apps — partly, and the limit is structural

Verified on this machine: an Excel instance created through COM has the command line

```
"C:\Program Files\Microsoft Office\Root\Office16\EXCEL.EXE" /automation -Embedding
```

and its parent process is `svchost.exe`, not the program that created it. That is
DCOM activation — Windows launches Office on the caller's behalf and keeps no record
linking the two. **So for COM-automated Excel the parent chain cannot name the
caller, and no amount of process inspection will change that.**

What the monitor can establish:

| Signal | Conclusion |
| --- | --- |
| `-Embedding` / `/automation` on the command line | A program is driving Excel, not a person |
| Parent is `svchost.exe` | Confirms DCOM activation |
| A document path in the arguments | Someone opened a file; the parent chain **is** meaningful here, and a parent of `explorer.exe` means a person double-clicked it |
| `SessionId` is 0 | No interactive desktop exists, so this is automation regardless of other signals |
| Owner is a service account | Same conclusion from a different direction |

When it detects COM automation it also lists candidate clients — live processes in
the same session that started before Excel. That is correlation, not proof, and the
log says so.

If you need certainty about which of your services drives Excel, the reliable fix is
in the calling code rather than here: have each service write its own marker (for
example set `Application.StatusBar` or a custom document property immediately after
`CreateInstance`), or stop using Excel COM on the server altogether. The report
pipeline already generates workbooks with ClosedXML, which needs no Excel process at
all.

### Everything else

The parent chain is reported for every breach and is reliable for normally launched
processes. Two details worth knowing: a parent that started *after* its child is
rejected, because Windows reuses PIDs and that pattern means the real parent exited
and something unrelated inherited its number; and if the parent has already exited
the chain is reported as empty rather than guessed at.

## Running it, and which users it can see

A Windows service runs under the account configured on the service, **not** the
account of whoever installed it. Installing as `user1` is therefore irrelevant; what
matters is the service account, and it decides how much the monitor can see.

Measured on this machine (411 processes, non-elevated standard user):

| Capability | Standard user | `LocalSystem` |
| --- | --- | --- |
| CPU usage of every process, including other users' and elevated ones | all 411 readable | all readable |
| Executable path and command line | **only 38% (156 of 411)** | all |
| Process owner | limited | all |

The consequence that matters: **CPU detection already works across every account
without elevation**, so even a standard-user service catches a runaway process
belonging to another user or to an administrator. What it loses is the identifying
detail — for 62% of processes the path and command line come back `(unavailable)`,
which defeats the point of the log.

So run it as `LocalSystem`. `sc.exe create` defaults to `LocalSystem` when `obj=` is
omitted, so the command below is already correct. Confirm afterwards with
`sc.exe qc "LRN - CPU Monitor"`; `SERVICE_START_NAME` should read `LocalSystem`.

One limit no account removes: session 0 has no interactive desktop, so the monitor
cannot read window titles. It does not rely on them — launch attribution uses command
lines and session IDs instead.

```powershell
dotnet publish -c Release
sc.exe create "LRN - CPU Monitor" binPath= "D:\LRN\Release\CpuMonitor\LRN.CpuMonitor.exe" start= auto
sc.exe start "LRN - CPU Monitor"
```

It also runs as a plain console application for testing, which is the quickest way to
tune the threshold against real load.
