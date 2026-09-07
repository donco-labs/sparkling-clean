# sparkling-clean

A zero-dependency macOS disk triage toolkit. Diagnose disk-pressure freezes,
reclaim space safely, and get warned before it happens again.

macOS abstracts away filesystem realities to keep the experience seamless. That
works until you combine a nearly-full disk, a slow backup destination and a heavy
developer toolchain — at which point the abstractions stop protecting you and
start hiding the problem.

Born from a real incident: a 24 GB MacBook Air freezing under watchdog timeouts,
with the drive serving a sustained **18 MB/s of pagein thrash** — memory pressure
wearing a disk costume. The SSD was healthy: 0 media errors, 0% endurance used.
The disk was 93% full, Time Machine had not completed a backup in 62 days, and
nothing had said so. Full writeup, including which theories turned out wrong:
[docs/POSTMORTEM.md](docs/POSTMORTEM.md).

## Install

```bash
brew tap donco-labs/tap
brew trust --formula donco-labs/tap/sparkling-clean
brew install sparkling-clean
```

Homebrew 6.0 refuses to load formulae from third-party taps until you trust them
— a formula is arbitrary Ruby that runs on install, so this gate is doing its
job. `--formula` trusts only this one; `brew trust donco-labs/tap` would trust
every formula the tap ever gains. Trust is recorded in
`~/.homebrew/trust.json` (or `$XDG_CONFIG_HOME/homebrew/trust.json`).

The formula is [Formula/sparkling-clean.rb](https://github.com/donco-labs/homebrew-tap/blob/main/Formula/sparkling-clean.rb)
— worth a read before you trust it, as with any tap.

Or clone and use `make` directly — the repo works without installing.

## Quick start

```bash
sparkling-clean report   # or: make report          # what is going on — read-only, changes nothing
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

### Menu bar

```bash
brew install --cask swiftbar
mkdir -p "$HOME/Library/Application Support/SwiftBar"
ln -sf "$PWD/extra/swiftbar/sparkling-clean.10m.sh" "$HOME/Library/Application Support/SwiftBar/"
open -a SwiftBar
```

Quote the destination rather than backslash-escaping the space — the escape does
not survive being copied out of a terminal or a rendered page. Create the folder
first as well: SwiftBar has no plugin directory until its first launch, so `ln`
fails on a missing target. Installed via Homebrew, the plugin lives under the
formula prefix instead:

```bash
ln -sf "$(brew --prefix)/opt/sparkling-clean/libexec/extra/swiftbar/sparkling-clean.10m.sh" \
       "$HOME/Library/Application Support/SwiftBar/"
```

On first launch SwiftBar asks which folder to use — point it at that one. It is
notarized but ships quarantined, so macOS shows its standard first-run dialog;
approve it in System Settings → Privacy & Security → Open Anyway.

Shows a monochrome SF Symbol and nothing else when healthy — a template image, so
it follows the menu bar appearance like any native item. A warning swaps the glyph;
only a critical condition earns any text, and then just the subject name. The
dropdown identifies itself, explains each non-OK check, and offers the fix: when
snapshots are holding space, it hands you `sparkling-clean thin` rather than
describing the problem and leaving you to search for the remedy. Reads the guard's `--json` (0.4 s) rather than the full report (tens of
seconds), so it is cheap to refresh.

Deliberately not a bundled app: `tmutil addexclusion` needs Full Disk Access,
snapshot thinning needs root, and a DMG needs Developer ID notarization to avoid
Gatekeeper. SwiftBar is already notarized and brew-installable, so this is ten
lines of config instead of a signing pipeline.

## Make targets

`make help` lists these at any time.

| Target | Does |
|---|---|
| `make report` | Full read-only diagnostic, ending in a Verdict block |
| `make brief` | Headline numbers only |
| `make check` | Run the guard once — exit `0` ok / `1` warn / `2` crit |
| `make dry` | Preview a tier 1+2 reclaim. Removes nothing |
| `make clean-safe` | Reclaim tier 1 — caches that regenerate silently |
| `make clean-more` | Reclaim tier 1+2 — adds re-downloadable caches |
| `make review` | List tier-3 *data* candidates for manual decision |
| `sparkling-clean thin` | Release space held by local Time Machine snapshots |
| `make docker` | Report Docker reclaimable space. Never touches volumes |
| `make docker-clean` | Prune build cache + untagged images, then compact |
| `make tm-status` | Which codified Time Machine exclusions are applied |
| `make tm-exclude` | Preview applying the exclusion list |
| `make tm-exclude-apply` | Apply it (needs Full Disk Access) |
| `make install-guard` | Install + load the launchd watchdog |
| `make uninstall-guard` | Unload + remove it |
| `make guard-status` | Is the guard loaded? |
| `make log` | Tail the guard's health log |
| `make lint` | Syntax-check every script and the plist |

## The guard

A launchd LaunchAgent labelled `com.sparklingclean.diskguard`. Checks every
2 hours plus once at login.

| What | Where |
|---|---|
| Installed plist (what launchd reads) | `~/Library/LaunchAgents/com.sparklingclean.diskguard.plist` |
| Script it runs | `bin/disk-guard.zsh` |
| Shared check logic | `bin/lib/common.zsh` → `sc_run_health_checks` |
| Plist template (in git) | `launchd/com.sparklingclean.diskguard.plist` |
| Health log | `~/.local/state/sparkling-clean/sparkling-clean.log` |
| Notification state | `~/.local/state/sparkling-clean/guard.state` |
| launchd stdout / stderr | `.guard.out.log` / `.guard.err.log` (gitignored) |

The template carries a `__SC_ROOT__` placeholder that `make install-guard`
substitutes with this repo's absolute path, so the installed plist is generated
rather than hand-edited.

**Editing the scripts takes effect immediately.** The plist runs
`bin/disk-guard.zsh` in place, not a copy, so the next scheduled run picks up
your changes. Re-run `make install-guard` only if you *move the repo* or change
the plist itself.

Force a run instead of waiting:

```bash
launchctl kickstart -k gui/$(id -u)/com.sparklingclean.diskguard
```

launchd rather than cron: it runs a missed interval on wake, so a sleeping laptop
still gets checked, and it runs inside the GUI session that notifications need.

### When it speaks

It **checks** every 2 hours; it **notifies** only on a level change, or once per
12 hours (`SC_RENOTIFY_H`) while a condition persists. Never on OK.

**A silent notification tray is the healthy steady state** — use `make log` to
confirm it is alive.

Signals come in two tiers:

| Tier | Contents | Escalates | Notifies |
|---|---|---|---|
| **CHECK** | disk %, Time Machine on/off, backup age, snapshot count | yes | yes |
| **NOTE** | jetsam / panic history | no | no |

Jetsam reports are evidence something *already happened*. Treating them as an
escalating signal keeps the guard at WARN for days after you fix the cause —
exactly when a monitor most needs to go quiet. If the cause is still live, disk %
or backup age catches it as a *current* condition.

Each check owns its own verdict and wording; the overall level is the worst
check, and the notification names **that** subsystem — `Backup CRIT: 61 days
stale`, not `Disk CRIT` on a machine with 121 GB free.

```
== Verdict ==
  OK    Disk       22% free
  OK    Backups    enabled
  OK    Backup     0d ago
  OK    Snapshots  2
  note  2 jetsam/panic report(s) in the last 3 days (past events, not a current fault)

OK    healthy
```

Thresholds, overridable by env: `SC_WARN_PCT` (15), `SC_CRIT_PCT` (10),
`SC_TM_WARN_D` (2), `SC_TM_CRIT_D` (7), `SC_RENOTIFY_H` (12).

## What is here

| Path | Purpose |
|---|---|
| `bin/disk-report.zsh` | Read-only diagnostic: space, snapshots, memory, jetsam events, SMART, offenders, TM exclusions, Verdict |
| `bin/reclaim.zsh` | Tiered reclamation, **dry-run by default** |
| `bin/docker-reclaim.zsh` | Docker space, **never touches volumes** |
| `bin/disk-guard.zsh` | Threshold watchdog; exit 0/1/2, desktop notification |
| `bin/lib/common.zsh` | Shared helpers — the APFS/snapshot/sparse-file knowledge and the health model live here |
| `launchd/` | LaunchAgent template for the guard |
| `docs/GUIDE.md` | **The comprehensive guide.** Why the tools mislead, how to read the evidence, what to clean in what order |
| `docs/REFERENCE.md` | Copy-paste command cheat sheet |
| `docs/POSTMORTEM.md` | The incident, and which lesson became which line of code |

## The four things worth knowing up front

Before running a single command: the standard macOS utilities are not telling you
the truth about your disk.

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

**3. Time Machine being "on" does not mean it is working.** A full disk purges
the local snapshot TM uses as its incremental reference; every backup then fails,
silently, for months. Check the age of the last *completed* backup:

```bash
defaults read /Library/Preferences/com.apple.TimeMachine | sed -n '/SnapshotDates/,/);/p' | tail -3
```

And a chain that *is* working can still be mostly garbage — `make report` flags
large reconstructible directories (container images, package caches, toolchains)
that are in every backup. The list is codified in `SC_TM_EXCLUDE_CANDIDATES`
(`bin/lib/common.zsh`) and applied with one command, so a rebuilt machine gets
the same policy:

```bash
make tm-status          # what is applied vs pending
make tm-exclude-apply   # apply the whole list
```

**4. Never `docker volume prune`.** A named volume reads as "dangling" the moment
its container is removed, but it still holds your data. Volumes are a small share
of Docker's footprint anyway; build cache and untagged images are where the space is.

## Safety

- Dry-run by default; destructive paths need `--apply`
- Tier 3 (real data: LLM models, Downloads) is **reported, never deleted**
- Pausing Time Machine is restored by a `trap`, so an interrupted run cannot
  leave the machine unbacked-up
- No `err_return` — diagnostic tools exit non-zero on benign conditions
  (`smartctl` returns 4 on Apple's harmless GetLogPage artifact)
- History never escalates current state, so a fixed problem stops alarming
- The report and the guard share one `sc_run_health_checks`, so they cannot
  disagree about whether the machine is healthy

## Requirements

macOS (APFS). Optional: `smartmontools` for SMART, `terminal-notifier` for nicer
notifications. Everything else is stock.
