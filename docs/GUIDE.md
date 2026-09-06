# macOS disk creep: diagnose, clean, and stay clean

A field guide written from a real incident (see [POSTMORTEM.md](POSTMORTEM.md)):
a 24 GB MacBook Air hitting sustained ~1 GB/s disk reads, freezes, and watchdog
timeouts. The SSD was perfectly healthy. The disk being 93% full was the cause.

Read §1 to understand *why* the obvious tools mislead you. Skip to §3 if you
just need commands.

---

## 1. The five things that will fool you

### 1.1 `df` is not measuring what you think

```
Filesystem      Size    Used   Avail Capacity   Mounted on
/dev/disk3s1s1  460Gi    12Gi    43Gi     22%   /
/dev/disk3s5    460Gi   396Gi    43Gi     91%   /System/Volumes/Data
```

Both rows show `460Gi` and `43Gi`. That is not a coincidence and it is not a bug:
APFS volumes share a single **container**. `Size` and `Avail` are container-wide
and identical on every row; only `Used` is per-volume. Never add the rows up,
and never read `460Gi` as either volume's own quota.

**Use this instead** — the one number that is not lying:

```bash
diskutil info /System/Volumes/Data | grep "Container Free"
```

### 1.2 GiB vs GB

`df -h` reports GiB (1024³). `diskutil` and Finder report GB (1000³).

```
df:       Used 396 Gi
diskutil: Used 425.5 GB     ← identical byte count, ×1.0737
```

This is why `du` totals never reconcile with `df -h`. Nothing is missing.

### 1.3 Snapshots pin deleted files

**The single most confusing behaviour in this whole area.** Delete 9 GB. Watch
free space not move at all. The files are gone from the directory tree, but a
local Time Machine snapshot taken *before* the deletion still references those
blocks, so they stay allocated.

```bash
tmutil listlocalsnapshots /
```

Anything listed is holding space. Release it:

```bash
sudo tmutil thinlocalsnapshots / 999999999999 4
```

macOS mints these roughly hourly whenever Time Machine is enabled — including
partway through your cleanup, re-pinning what you just deleted. `reclaim.zsh`
handles this by pausing TM for the duration and thinning at the end.

### 1.4 Purgeable space (why Finder disagrees)

Finder and About This Mac count snapshots and evictable caches as free, because
macOS *can* release them under pressure. `df` counts only genuinely free blocks.
Finder will cheerfully claim 80 GB free while `df` says 20 GB. Under pressure,
reality behaves closer to `df`.

### 1.5 Sparse files (why `ls -lh` lies about Docker)

```bash
ls -lh Docker.raw     # 460G   ← the ceiling it may grow to
du -h  Docker.raw     #  42G   ← what is actually allocated
```

Always `du`. This applies to any disk image, VM, or database file.

---

## 2. Is it the disk, or is it the SSD?

Run SMART first so you can stop worrying about hardware:

```bash
sudo smartctl -a /dev/disk0
```

Five fields decide it:

| Field | Healthy | Meaning |
|---|---|---|
| `Critical Warning` | `0x00` | any nonzero = real trouble |
| `Available Spare` | 100% (thresh 99%) | retired-block reserve |
| `Percentage Used` | 0–90% | endurance consumed |
| `Media and Data Integrity Errors` | `0` | uncorrectable errors, ever |
| `Error Information Log Entries` | `0` | logged failures |

### Ignore this line

```
Read 1 entries from Error Information Log failed:
GetLogPage failed: system=0x38, sub=0x0, code=745
```

Benign, on every Apple Silicon Mac. Decoded: `system=0x38` is IOKit, `code=745`
is `kIOReturnDeviceError`. Apple's NVMe passthrough exposes **only** SMART/Health
log page `0x02`; smartctl also asks for Error Information page `0x01`, and the
driver refuses. The tell that it is a tool artifact: the log reports **0 entries**
and smartctl tries to read 1 anyway.

It also makes `smartctl` exit non-zero (4). Do not let that abort your scripts.

### Reading the lifetime counters

```
Data Units Read:     77,217,786 [39.5 TB]
Data Units Written:  27,033,148 [13.8 TB]
Power On Hours:      438
```

39.5 TB read over 438 hours is **90 GB/hour sustained**. No normal workload does
that. A read:write ratio near 3:1 at that rate is the signature of **pagein
thrash** — not disk wear. Which points at memory, not storage.

---

## 3. The actual failure mode

Here is the chain that produces "1 GB/s disk and the machine freezes":

```
disk fills past ~90%
        ↓
macOS cannot grow a swapfile   (swap lives on the same volume)
        ↓
RAM pressure has no relief valve
        ↓
page cache evicts executables and mmapped files
        ↓
they are immediately re-read from SSD  ← the 1 GB/s
        ↓
kernel stalls on I/O → watchdog timeout → jetsam kills apps
```

Confirm each link:

```bash
sysctl vm.swapusage        # total = 0.00M while RAM is full = no relief valve
vm_stat | grep -E 'Pageins|Pageouts'   # pageins >> pageouts = read thrash
ls /Library/Logs/DiagnosticReports/ | grep -Ei 'jetsam|panic|watchdog'
```

**Key insight:** swap at zero is not itself a fault. Swap at zero *while RAM is
saturated and the disk is full* is the fault. Free the disk and the valve returns.

Note `PhysMem: 23G used, 259M unused` is **normal** on macOS — it uses all RAM as
cache. Judge pressure by jetsam events, compressor size, and swap behaviour, not
by "unused".

---

## 4. Reclaim, in order

Always dry-run first. Everything here is dry-run by default.

```bash
make report        # what is going on
make dry           # what tier 1+2 would free
make clean-safe    # tier 1: caches that regenerate silently
make clean-more    # tier 1+2: adds re-downloadable caches
make review        # tier 3: data — reported, never auto-deleted
```

### Tier 1 — regenerating caches, no user action to restore

| Target | Typical | Note |
|---|---|---|
| `~/Library/Developer/Xcode/iOS DeviceSupport` | **10–25 GB** | biggest safe win; regenerates on next device connect |
| Homebrew cache (`brew cleanup -s --prune=all`) | 5–10 GB | also clears its accumulated vendored Rubies |
| `~/Library/Developer/Xcode/DerivedData` | 3–10 GB | rebuilds |
| `~/Library/Caches/{go-build,JetBrains,pip,Yarn,node-gyp}` | 1–6 GB | all rebuild |

### Tier 2 — costs a re-download or rebuild

`~/.gradle/caches`, `~/Library/Caches/ms-playwright` (browser binaries),
`xcrun simctl delete unavailable`.

### Tier 3 — data. Decide by hand.

Local LLM models (`~/.ollama`, `~/models`), `~/Downloads`, alternative container
runtimes. The scripts **report** these and never delete them.

### Always end with a thin

`make clean-safe` does it for you. Manually:

```bash
sudo tmutil thinlocalsnapshots / 999999999999 4
```

Then read the real number:

```bash
diskutil info /System/Volumes/Data | grep "Container Free"
```

---

## 5. Docker

```bash
make docker         # report
make docker-clean   # prune + compact
```

### The volume landmine

**Never run `docker volume prune`.** A named volume shows as "dangling" the
moment its container is removed — but it still holds the data. Prune cannot
distinguish `ambit_postgres-data` from scratch space, and volumes are typically
a single-digit share of Docker's footprint anyway. `docker-reclaim.zsh` reports
unreferenced volumes, flags which have human-given names, and deletes none.

Removing a *container* also un-protects its image **and** its named volumes.

### Where the space actually is

```
Build Cache      10.85 GB   0 active   ← safest possible reclaim
Images 65 total  23.45 GB   16.67 GB reclaimable
  └─ repo:<none> entries are superseded layers from re-pulled tags
Volumes          9.76 GB    ← leave alone
```

### Pruning does not shrink `Docker.raw`

Pruning frees space *inside* the VM's filesystem. The host-side sparse file only
shrinks when Docker Desktop **compacts it on a clean shutdown**. In the source
incident this reclaimed 20 GB by itself (42 G → 22 G) with no prune at all.

So: prune, then quit Docker Desktop properly. If it still will not shrink,
Settings → Resources → Disk image size — which **recreates the image and
destroys every container, image and volume inside it**.

### Transient 500s are usually not a wedged daemon

```
500 Internal Server Error for API route .../v1.55/info
```

Docker Desktop's **Resource Saver** stops the VM after a few minutes idle. During
teardown the socket answers but every route 500s. That looks identical to a hang.
Wait a minute and re-check before reaching for `kill -9` — a hard kill can leave
the VM's filesystem dirty, and your database volumes live in there.

If you must kill it: `kill <pid>` (SIGTERM) on the top-level `com.docker.backend`,
wait 30 s, and only then escalate. Leave `com.docker.vmnetd` alone — it is a
launchd-managed privileged helper that respawns anyway.

---

## 6. The other half: I/O loops

Free disk alone will not fix sustained background I/O. Check for a
**cloud-sync ↔ Spotlight loop**:

Google Drive with `force_file_provider_materialization=on` downloads real bytes
on access. Spotlight indexes what appears. Indexing touches files. Drive
re-materializes. Round and round, at hundreds of MB/s.

Fix: System Settings → Spotlight → Search Privacy → **+** → add the **account
folder**, not just `My Drive`:

```
/Users/<you>/Library/CloudStorage/GoogleDrive-<account>
```

`My Drive` alone leaves `Other computers/` and `.shortcut-targets-by-id/`
indexed — often the larger half. `~/Library` is hidden in the picker; press
**⌘⇧G** and paste the path. Click **Done** — nothing commits until then.

Verify (`0` = excluded):

```bash
mdfind -onlyin ~/Library/CloudStorage/GoogleDrive-<account> -count "kMDItemFSName == '*'"
```

Other usual suspects: Time Machine running during the storm, duplicate language
servers (two `gopls` = 767 MB), and multiple container runtimes installed at once.

---

## 7. Staying clean

```bash
make install-guard    # launchd, checks every 2h, notifies on WARN/CRIT
make guard-status
make log
```

Thresholds default to 15% (warn) / 10% (critical). Override:

```bash
SC_WARN_PCT=20 SC_CRIT_PCT=12 make check
```

The guard also escalates to WARN on secondary signals: ≥5 local snapshots,
Time Machine left off, or any jetsam/panic report in the last 3 days.

launchd rather than cron: launchd runs a missed interval on wake, so a sleeping
laptop still gets checked, and it runs in the GUI session that notifications need.

---

## 8. Safety rules these scripts follow

1. **Dry-run by default.** Destructive paths require `--apply`.
2. **Never delete data**, only caches. Tier 3 is report-only, always.
3. **Never `docker volume prune`.**
4. **Time Machine is restored by a trap**, so an interrupted run cannot leave
   the machine unbacked-up.
5. **No `err_return`.** Diagnostic tools exit non-zero on benign conditions —
   `smartctl` returns 4 on the Apple GetLogPage artifact, `docker` fails when
   stopped, `du` on unreadable dirs. An early version of these scripts silently
   aborted halfway for exactly this reason.
