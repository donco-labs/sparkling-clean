# sparkling-clean

macOS disk triage toolkit. Diagnose disk-pressure freezes, reclaim space safely,
and get warned before it happens again.

Born from a real incident: a 24 GB MacBook Air hitting sustained ~1 GB/s disk
reads and watchdog freezes. The SSD was healthy. The disk being 93% full was the
cause — macOS could not grow a swapfile, so RAM pressure turned into pagein
thrash and jetsam kills. Full writeup: [docs/POSTMORTEM.md](docs/POSTMORTEM.md).

## Quick start

```bash
make report          # what is going on — read-only, changes nothing
```
```bash
make dry             # what a cleanup would free — removes nothing
```
```bash
make clean-safe      # reclaim caches that regenerate silently
```
```bash
make install-guard   # launchd watchdog: checks every 2h, notifies on WARN/CRIT
```

## What is here

| Path | Purpose |
|---|---|
| `bin/disk-report.zsh` | Read-only diagnostic: space, snapshots, memory, jetsam events, SMART, offenders |
| `bin/reclaim.zsh` | Tiered reclamation, **dry-run by default** |
| `bin/docker-reclaim.zsh` | Docker space, **never touches volumes** |
| `bin/disk-guard.zsh` | Threshold watchdog; exit 0/1/2, desktop notification |
| `bin/lib/common.zsh` | Shared helpers — the APFS/snapshot/sparse-file knowledge lives here |
| `launchd/` | LaunchAgent for the guard |
| `docs/GUIDE.md` | **The comprehensive guide.** Why the tools mislead, how to read the evidence, what to clean in what order |
| `docs/REFERENCE.md` | Copy-paste command cheat sheet |
| `docs/POSTMORTEM.md` | The incident, and which lesson became which line of code |

## The three things worth knowing up front

**1. `df` is misleading on APFS.** Volumes share one container, so `Size` and
`Avail` are container-wide and identical on every row — never sum them. `df -h`
also reports GiB while `diskutil` and Finder report GB. Use:

```bash
diskutil info /System/Volumes/Data | grep "Container Free"
```

**2. Local snapshots absorb your deletions.** Delete 9 GB, watch free space not
move. A Time Machine snapshot taken before the delete still references those
blocks. Always finish with a thin — `reclaim.zsh` does it automatically:

```bash
sudo tmutil thinlocalsnapshots / 999999999999 4
```

**3. Never `docker volume prune`.** A named volume reads as "dangling" the moment
its container is removed, but it still holds your data. Volumes are a small share
of Docker's footprint anyway; build cache and untagged images are where the space is.

## Safety

- Dry-run by default; destructive paths need `--apply`
- Tier 3 (real data: LLM models, Downloads) is **reported, never deleted**
- Pausing Time Machine is restored by a `trap`, so an interrupted run cannot
  leave the machine unbacked-up
- No `err_return` — diagnostic tools exit non-zero on benign conditions
  (`smartctl` returns 4 on Apple's harmless GetLogPage artifact)

## Requirements

macOS (APFS). Optional: `smartmontools` for SMART, `terminal-notifier` for nicer
notifications. Everything else is stock.
