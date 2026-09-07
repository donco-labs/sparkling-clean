# My Mac Was Reading 90 GB an Hour. The SSD Was Fine.

*A night of chasing a "failing disk" that turned out to be three separate problems, one of which had silently killed my backups two months earlier.*

---

It started the way these things do: the machine would freeze, hard, for ten or twenty seconds at a stretch. Watchdog timeouts. Activity Monitor showing disk activity pinned near 1 GB/s with nothing obvious to explain it.

A 24 GB M-series MacBook Air, 512 GB SSD, macOS 26. My first thought was the same as yours would be: the drive is dying.

So I pulled SMART data.

```
SMART overall-health self-assessment test result: PASSED

Critical Warning:                   0x00
Available Spare:                    100%
Percentage Used:                    0%
Media and Data Integrity Errors:    0
Error Information Log Entries:      0

Read 1 entries from Error Information Log failed:
GetLogPage failed: system=0x38, sub=0x0, code=745
```

That last line looked like the smoking gun. It is not.

## The red herring

`system=0x38` is IOKit. `code=745` is `kIOReturnDeviceError`. Alarming, and completely meaningless here.

Apple Silicon Macs expose exactly one NVMe log page through their driver: `0x02`, the health page. `smartctl` also asks for page `0x01`, the Error Information Log, and the driver refuses. Every Apple Silicon Mac produces this line.

The tell is two lines above it: **`Error Information Log Entries: 0`**. There is nothing to read. `smartctl` tries to read one entry anyway, gets refused, and reports a device error.

It also makes `smartctl` exit with status 4 — which later killed the first version of my own diagnostic script, silently, at exactly the section written to explain the error away.

> **Takeaway.** On Apple Silicon, `GetLogPage failed … code=745` is a tool artifact, not a disk fault. Judge the drive by `Critical Warning`, `Available Spare`, `Percentage Used`, and `Media and Data Integrity Errors`. All four were perfect.

## What SMART actually told me

The health fields were clean. The lifetime counters were not normal.

```
Data Units Read:     77,217,786 [39.5 TB]
Data Units Written:  27,033,148 [13.8 TB]
Power On Hours:      438
```

39.5 TB read across 438 powered-on hours is **90 GB per hour, sustained, for the life of the machine**. No workload I run does that. And the read:write ratio is nearly 3:1.

That ratio is the diagnosis. Heavy *writing* means a busy machine. Heavy *reading* at three times your write volume means the same data is being read over and over — the signature of **pagein thrash**. The disk was not failing. It was being flogged.

Confirmed live:

```
Pageins:   1,043,671      (~16 GB — in a 16-minute uptime)
Pageouts:      6,233
PhysMem:   23G used, 259M unused
vm.swapusage: total = 0.00M
```

## Three ways `df` lied to me

Before I could see how full the disk was, I had to get past the tooling.

```
Filesystem      Size    Used   Avail Capacity   Mounted on
/dev/disk3s1s1  460Gi    12Gi    43Gi     22%   /
/dev/disk3s5    460Gi   396Gi    43Gi     91%   /System/Volumes/Data
```

**One.** Both rows show `460Gi` and `43Gi`. Not a coincidence and not a bug: APFS volumes share a single container. `Size` and `Avail` are container-wide and identical on every row. Only `Used` is per-volume. Never sum the rows.

**Two.** `df -h` reports GiB (1024³). `diskutil` and Finder report GB (1000³). The same 396 GiB shows as 425.5 GB. This is why `du` totals never reconcile with `df -h`.

**Three.** Finder counts "purgeable" space — snapshots and evictable caches — as free, because macOS *can* release it under pressure. `df` counts only genuinely free blocks. Finder will cheerfully claim 80 GB free while `df` says 20 GB, and under pressure reality behaves like `df`.

> **Takeaway.** One command tells the truth:
> ```
> diskutil info /System/Volumes/Data | grep "Container Free"
> ```

It said 36.6 GB free. **93% full.**

## The chain nobody diagnoses correctly

It starts with that lie of omission from Finder. You glance at storage, see 50 GB free, and assume you have breathing room — and because you have breathing room, you never look again.

A heavy polyglot toolchain doesn't just move gigabytes. It generates hundreds of thousands of tiny transient files — `~/.cache` alone held 107,760 of them. The disk creeps up over months, and nothing warns you, because 90% full still looks like plenty of room.

Then it stops being a storage problem and becomes a memory one. Here is what actually produces "1 GB/s of disk reads and the machine locks up":

```
disk fills past ~90%
      ↓
macOS cannot grow a swapfile   (swap lives on that same volume)
      ↓
RAM pressure has no relief valve
      ↓
page cache evicts executables and mmapped files
      ↓
they are re-read from SSD immediately   ← the 1 GB/s
      ↓
kernel stalls on I/O → watchdog timeout → jetsam kills your apps
```

The subtle part is the swap reading. `vm.swapusage: total = 0.00M` looks *healthy* in isolation — plenty of people run for weeks without touching swap.

> **Takeaway.** Swap at zero is not a problem. Swap at zero **while RAM is saturated and the disk is nearly full** is the failure: macOS cannot create the swapfile it needs, so memory pressure goes straight to app kills. There was a `JetsamEvent` in `/Library/Logs/DiagnosticReports/` from earlier that day confirming it.

And `23G used, 259M unused` from that same dump is **normal** on macOS — it uses all RAM as cache. Judge pressure by jetsam events, compressor size and swap behaviour, never by "unused".

## Deleting 9 GB and freeing nothing

I started clearing caches. Cleared 8.9 GB of Homebrew downloads. Re-checked free space.

It hadn't moved. Not "moved a little." Zero.

```
tmutil listlocalsnapshots /
com.apple.TimeMachine.2026-09-05-215646.local
```

A local Time Machine snapshot taken minutes earlier still referenced those blocks. Deleting the files removed the directory entries; the blocks stayed allocated. macOS mints these roughly hourly whenever Time Machine is on — including partway through your cleanup, re-pinning what you just deleted.

> **Takeaway.** Finish every cleanup with a thin, or it did nothing:
> ```
> sudo tmutil thinlocalsnapshots / 999999999999 4
> ```
> Better: pause Time Machine for the duration so it cannot re-pin mid-run — and make sure whatever pauses it turns it back on. I left mine off for half an hour by hand, which is a lousy way to run a backup policy.

## The 460 GB file that was 42 GB

```
$ ls -lh Docker.raw
460G
$ du -h Docker.raw
 42G
```

`ls -lh` reports logical size. `Docker.raw` is sparse — 460 GB is the ceiling it may grow to, not what it occupies. Always `du` for disk images, VM bundles, and database files.

Then Docker Desktop did something I didn't expect. Its backend had been idle, and while I was poking at it, macOS's Resource Saver stopped the VM. On the way out, Docker **compacted the image**: 42 GB → 22 GB. Twenty gigabytes reclaimed by an app shutting down cleanly.

That taught me two things. Pruning frees space *inside* the VM; only a clean Docker Desktop shutdown shrinks the host-side file. And the transient `500 Internal Server Error` responses I'd seen from the Docker API were teardown, not a wedged daemon. I had been one impatient `kill -9` away from leaving the VM's filesystem dirty — with my Postgres volumes inside it.

By the end of that night: **36.6 GB → 121.4 GB free.** Load average fell from 10.76 to 2.29. (It settles at 116.7 GB a day later, once the backup below has run and taken its own snapshots.)

---

## Then I checked when my last backup finished

This is the part I want you to act on.

Time Machine was on. It had always been on. System Settings said so.

```
SnapshotDates (completed backups):
  2026-05-24
  2026-06-09
  2026-07-04
  2026-07-05
  2026-07-06     ← last one
  ...nothing...
```

**Sixty-two days.** No completed backup since July 6, on a machine that showed "Time Machine: On" the entire time and never once told me otherwise.

The mechanism is the same root cause:

```
ReferenceLocalSnapshotDate = 2026-07-06 13:44:34
```

Time Machine keeps a local snapshot as the baseline it diffs against for incrementals. When the disk filled, macOS purged that snapshot's contents to reclaim space. It stayed in the list, marked `(dataless)` — present, but holding nothing. With no valid baseline, every subsequent backup failed. And retried. And failed.

Nine attempts on the final day alone, each burning CPU and I/O into the very pressure that caused it. `backupd` even tripped macOS's own CPU-resource reporter. None of it surfaced.

> **Takeaway.** "Enabled" and "working" are different questions. Check the age of the last *completed* backup:
> ```
> defaults read /Library/Preferences/com.apple.TimeMachine \
>   | sed -n '/SnapshotDates/,/);/p' | tail -3
> ```
> Read `SnapshotDates` (completions), not `AttemptDates` — the latter doesn't record every attempt, and I initially misread its gap as a two-month-longer outage than had actually occurred.
>
> Note this reads the preference file directly. `tmutil latestbackup` needs Full Disk Access, which a scheduled agent won't have.

## The re-seed, and what it exposed

With the reference snapshot gone, Time Machine abandoned the broken chain and started over: **350 GB, 3.48 million files**, to a consumer NAS over Wi-Fi. It ran for ten and a half hours.

Watching it taught me the thing I'd have most liked to know a year ago.

Partway through, throughput collapsed from 22 MB/s to 1.4 MB/s while `backupd` sat at **173% CPU moving 7.5 files per second**. Not waiting on the network — grinding. Wi-Fi was pristine throughout: 802.11ax, −47 dBm, 1080 Mbps negotiated.

The cost wasn't bytes. It was **files**.

| Directory | Size | Files |
|---|---|---|
| `~/.ollama` | 6.6 GB | **29** |
| `~/Library/Containers/com.docker.docker` | 24.1 GB | **148** |
| `~/.pub-cache` | 1.2 GB | **61,296** |
| `~/.cache` | 8.8 GB | **107,760** |

`~/.ollama` is five times larger than `~/.pub-cache` and roughly two thousand times cheaper to back up. Big sequential blobs stream. Tiny files are a network round-trip each.

And you pay twice. Later, during the post-backup thinning pass, I watched it delete a superseded backup one `unlink` at a time over SMB — grinding through `~/.cache/uv/archive-v0/…`, the Python `uv` package cache. **Whatever you back up, you eventually pay to delete.**

None of that data was worth keeping. It's all reconstructible from a registry, a lockfile, or a re-download.

I excluded 75 GB across eleven directories — container images, package caches, toolchains — using sticky path exclusions so they survive the folders being deleted and recreated:

```bash
sudo tmutil addexclusion -p ~/.cache ~/.npm ~/.ollama ~/.rustup
```

The next incremental:

```
Total copied: 2455.05 MB      Avg speed: 192.91 MB/min
```

**About thirteen minutes, against ten and a half hours.**

That first one still carried some pre-exclusion state. Once the full list was
applied, the next four settled at **five to ten minutes** each — a routine
incremental to a consumer NAS over Wi-Fi, which is what it should have been all
along.

And afterwards, for the first time in the whole exercise:

```
vm.swapusage: total = 5120.00M  used = 3408.25M
```

The safety valve was working again.

One more thing was quietly making it worse. Checking what held files open on the
backup volume:

```
73 open handles  mds_store
 5 open handles  mds
```

Spotlight was indexing the backup destination — an 819 GB sparsebundle, over SMB.
You cannot usefully Spotlight-search a Time Machine backup; it has its own browse
interface. So this was pure competition for the same slow link, on every backup.

Worth checking, and a trap inside a trap: `sudo mdutil -i off /Volumes/<backup>`
does **not** disable it. It drops to `kMDConfigSearchLevelFSSearchOnly` and still
reports `Indexing enabled`. The exclusion that actually works is System Settings
→ Spotlight → Search Privacy, and the volume must be mounted when you add it —
which for a network destination means during a backup.

> **Takeaway.** Filter exclusion candidates by **file count**, not size. A 300 MB directory with 200,000 tiny files costs far more than 6 GB of model weights. And exclude subpaths deliberately — `~/.cargo/registry`, not `~/.cargo`, which holds credentials; `~/.m2/repository`, not `~/.m2`.

## What I built, and what it taught me about monitoring

Every signal was present for days beforehand. Jetsam events, macOS's own excessive-disk-write reports, free space falling. Nothing was watching.

So I wrote one. `sparkling-clean` is about a thousand lines of zsh with no runtime dependencies — a read-only diagnostic, a tiered reclaimer that is dry-run by default, and a launchd agent that checks every two hours and stays silent unless something changes.

The diagnostic ends with the answer rather than making you assemble it:

```
== Verdict ==
  OK    Disk       22% free
  OK    Backups    enabled
  OK    Backup     0d ago
  OK    Snapshots  2
  note  4 kernel report(s) in the last 3 days — none from memory exhaustion

OK    healthy
```

Every check in it exists because this incident hid behind the absence of it. The
backup-age check is the one I would install on someone else's machine unasked.

It also names what is in your backups that should not be, sorted by the metric
that actually costs — and hands you the command:

```
WARN  75.4 GB / 104,849 files of rebuildable data in every backup:
        24.1 GB        148 files  ~/Library/Containers/com.docker.docker
         8.8 GB    107,760 files  ~/.cache
         1.2 GB     61,296 files  ~/.pub-cache
      …
        sudo tmutil addexclusion -p …
```

That list is versioned in the repo, so a rebuilt machine gets the same policy from
one command instead of a memory of which caches were safe.

The interesting part wasn't the scripts, though. It was getting the *alerting*
right, and I got it wrong twice first.

**Mistake one: history escalating current state.** I treated jetsam reports as an alerting signal. After the disk was fixed, the guard kept reporting WARN for three days over kills that had already stopped — precisely when a monitor most needs to go quiet. Now there are two tiers: *checks* are current conditions and escalate; *notes* are historical context and never do.

**Mistake two: naming the wrong subsystem.** Every notification title was hardcoded `"Disk ${level}"` and the message body was built entirely from the disk branch. So the stale-backup alert announced itself as **"Disk CRIT: 22% free"** on a machine with 121 GB free — naming the wrong problem and contradicting its own threshold in the same sentence. Now each check owns its verdict and its wording, and the alert names the subsystem that's actually unhealthy.

**A third, subtler one:** not all `JetsamEvent`s mean the same thing. `per-process-limit` is one process hitting its own ceiling — routine. `vm-pageshortage` is real memory exhaustion. Counting them together cries wolf over normal housekeeping. And my first classifier used `sudo -n grep`, which fails whenever a password is required — so it would have reported "no memory events" forever, silently, with no way to tell that answer apart from the truth.

> **Takeaway.** A check that reads *healthy* when it cannot tell is worse than no check. Report UNKNOWN. This bit me three separate times in one night, in three different scripts.

## Who this actually affects

Honest scoping, because I don't think this is universal.

This bites when three conditions coincide: **a nearly-full disk, a slow backup destination, and a heavy polyglot toolchain.** Miss any one and you never see it.

- With 500 GB free, the swap valve never fails and none of this happens.
- With a fast local SSD as your destination, the file-count cost is still there — it's just ninety seconds instead of ten hours, so you never notice.
- Most developers never back up a dev machine at all beyond git and cloud sync, and quietly accept that a rebuild costs a day.

I'd been running all three conditions for months without knowing. The disk crept up, the backups died, and macOS never mentioned either.

## Four checks worth running right now

They take under a minute.

```bash
# 1. Real free space (not what df or Finder tell you)
diskutil info /System/Volumes/Data | grep "Container Free"
```
```bash
# 2. When did a backup last actually COMPLETE?
defaults read /Library/Preferences/com.apple.TimeMachine \
  | sed -n '/SnapshotDates/,/);/p' | tail -3
```
```bash
# 3. Are snapshots holding space you think you freed?
tmutil listlocalsnapshots /
```
```bash
# 4. Is a cache in every one of your backups?
tmutil isexcluded ~/.cache
```

If #2 surprises you, this article did its job.

---

## Getting it

```bash
brew tap donco-labs/tap
brew trust --formula donco-labs/tap/sparkling-clean
brew install sparkling-clean
```

(Homebrew 6 refuses formulae from third-party taps until you trust them. The
formula is thirty lines and copies scripts into `libexec`; read it first, which is
the point of the gate.)

Then:

```bash
sparkling-clean report          # the diagnostic above
sparkling-clean install-guard   # the watchdog, every 2h
sparkling-clean reclaim         # dry-run; --apply to actually reclaim
```

Every destructive path is dry-run until you pass `--apply`, real data is reported
and never deleted, and pausing Time Machine is restored by a trap so an
interrupted run cannot leave a machine unbacked-up. It is macOS-only, it has been
proven on exactly one machine, and the exclusion list is tuned to my toolchain —
treat it as a starting point rather than gospel.

The repo's `docs/` directory carries the full postmortem: twelve lessons, each
naming which mistake produced which line of code, including the four theories that
turned out wrong. If you only read one, read the one about a monitor that reports
healthy when it cannot tell.

**[github.com/donco-labs/sparkling-clean](https://github.com/donco-labs/sparkling-clean)**
