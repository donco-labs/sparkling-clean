# Incident: pathological disk I/O and watchdog freezes

**Date:** 2026-09-05 · **Host:** MacBook Air, Apple M-series, 24 GB RAM, 512 GB SSD
**Symptom:** sustained ~1 GB/s disk activity, machine freezes, watchdog timeouts
**Root cause:** disk at 93% capacity prevented swapfile growth
**Resolution:** reclaimed 84.8 GB · **Hardware fault: none**

---

## Timeline

| Time | Event |
|---|---|
| 13:26 | `JetsamEvent` — kernel memory-pressure killer fires |
| 15:55 | macOS excessive-disk-write monitor trips twice |
| ~20:50 | Investigation opens with `smartctl` output |
| 21:00 | Disk found at 93% (34 GiB free); 4 local snapshots |
| 21:05 | Snapshot thin → +9 GiB |
| ~21:15 | Homebrew cache cleared — free space does not move (snapshot re-pin) |
| 21:30 | Xcode + dev caches cleared, TM paused, thin → 100.3 GB free |
| ~21:40 | Docker Desktop self-exits, compacts `Docker.raw` 42 G → 22 G |
| 21:50 | 121.4 GB free · load 10.76 → 2.29 · Spotlight/Drive loop closed |

---

## What the evidence said

SMART was clean on every field that matters — `Critical Warning 0x00`,
`Available Spare 100%`, `Percentage Used 0%`, `Media and Data Integrity Errors 0`.
The drive was never the problem.

The lifetime counters pointed at the real cause:

```
Data Units Read:     39.5 TB     ← 90 GB/hour over 438 power-on hours
Data Units Written:  13.8 TB
```

A 2.9:1 read:write ratio at 90 GB/h is not a workload. It is pagein thrash.
Confirmed live:

```
Pageins:  1,043,671  (~16 GB in a 16-minute uptime)
Pageouts:     6,233
PhysMem:  23G used, 259M unused
vm.swapusage: total = 0.00M
```

Swap at zero with RAM saturated is the tell. macOS could not grow a swapfile
because the volume was at 93%, so memory pressure had no relief valve. Page cache
evicted executables, which were immediately re-read from SSD, at gigabytes per
second, until the kernel stalled long enough to trip the watchdog.

Aggravating factors, all visible in `DiagnosticReports`: Time Machine backing up
to a network NAS throughout, Spotlight indexing a Google Drive mount that was
simultaneously materializing files on access, a stopped 42 GB Docker VM image,
two `gopls` instances at 767 MB combined, and three container runtimes installed
side by side.

---

## Where the 84.8 GB came from

| Source | Reclaimed |
|---|---|
| Docker Desktop compacting `Docker.raw` on clean exit | 20 GB |
| Xcode `iOS DeviceSupport` | 22 GB |
| Local Time Machine snapshots | 9 GB |
| Homebrew cache (incl. 8 vendored Rubies) | 9 GB |
| Xcode `DerivedData` + JetBrains/go-build/rattler caches | ~11 GB |
| Everything else | ~14 GB |

---

## Lessons that became code

1. **Snapshots silently absorb deletions.** Clearing 8.9 GB of Homebrew cache
   moved free space by *zero* because a snapshot minted minutes earlier still
   referenced it. → `reclaim.zsh` pauses TM and thins at the end.

2. **Pausing Time Machine must be self-restoring.** It was left off for ~30
   minutes because a manual `tmutil disable` had no counterpart. → `sc_tm_pause`
   installs a `trap … EXIT INT TERM`.

3. **`err_return` is wrong for diagnostics.** The first `disk-report.zsh` aborted
   silently at the SMART section: `smartctl` exits 4 on the benign Apple
   GetLogPage artifact. The script was killed by the exact error the script
   exists to explain away.

4. **Transient 500s ≠ wedged daemon.** Docker's API was probed mid-shutdown and
   read as hung. It was Resource Saver stopping the VM; left alone, it exited
   cleanly and compacted 20 GB. A `kill -9` would have lost that and risked the
   Postgres volumes.

5. **A clean Docker shutdown is a reclaim strategy.** It out-performed the entire
   planned prune (20 GB vs ~25 GB estimated) and required no decisions.

6. **Exclude the cloud-sync parent, not the visible child.** Excluding `My Drive`
   left `Other computers/` and `.shortcut-targets-by-id/` indexed.

7. **Time Machine had been dead for 105 days and said nothing.** `AttemptDates`
   jumps 2026-05-23 → 2026-09-05; `SnapshotDates` (actual completed backups) ends
   2026-07-06. `ReferenceLocalSnapshotDate` pointed at
   `com.apple.TimeMachine.2026-07-06-094434.local` — the snapshot found marked
   **`(dataless)`**: macOS had purged its contents under space pressure, leaving
   TM with no baseline to diff against. Every backup since failed, retrying nine
   times on the final day, burning CPU and I/O into the same storm. Settings
   showed Time Machine "on" throughout.

   Thinning that snapshot during cleanup forced TM to abandon the broken chain
   and start a 350 GB full re-seed — the correct outcome, but note the chain was
   already unusable before we touched it.

   → `sc_tm_days_since_backup` now checks the age of the last *completed* backup
   in both the report and the guard, reading the world-readable TM plist so it
   works unprivileged under launchd.

8. **Threshold alerting beats forensics.** Every signal — jetsam events, disk-write
   diags, falling free space — was present for days beforehand. Nothing was
   watching. → `disk-guard.zsh` + launchd.
