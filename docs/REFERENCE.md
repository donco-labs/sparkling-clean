# Command reference

Copy-paste cheat sheet. Fuller explanations in [GUIDE.md](GUIDE.md).

## Measure

```bash
# The only honest number (APFS container, base-10 GB)
diskutil info /System/Volumes/Data | grep "Container Free"
```
```bash
# Per-volume used (remember: Size/Avail are container-wide, identical per row)
df -h / /System/Volumes/Data
```
```bash
# Allocated vs logical — always du for sparse files (disk images, VMs, DBs)
du -h  ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
ls -lh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
```
```bash
# Biggest consumers under home
du -xh -d 3 ~ 2>/dev/null | sort -rh | head -25
```
```bash
# Whole data volume
sudo du -xh -d 2 /System/Volumes/Data 2>/dev/null | sort -rh | head -30
```

## Snapshots — the hidden space

```bash
tmutil listlocalsnapshots /
```
```bash
sudo tmutil thinlocalsnapshots / 999999999999 4
```
```bash
# Pause TM during cleanup so it cannot re-pin deletions. ALWAYS re-enable.
sudo tmutil disable
sudo tmutil enable
```

## Health signals

```bash
sudo smartctl -a /dev/disk0
```
```bash
# Kernel distress: jetsam kills, panics, excessive-write trips
ls -lt /Library/Logs/DiagnosticReports/ | grep -Ei "jetsam|panic|watchdog|disk writes" | head
```
```bash
sysctl vm.swapusage          # 0 while RAM is full + disk full = the failure mode
vm_stat | grep -E "Pageins|Pageouts|compressor"
top -l 1 -n 0 | grep PhysMem
```

## Reclaim — safe tier

```bash
rm -rf ~/Library/Developer/Xcode/iOS\ DeviceSupport/*
```
```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/*
```
```bash
brew cleanup -s --prune=all          # preview with -n
```
```bash
rm -rf ~/Library/Caches/{go-build,JetBrains,rattler,node-gyp,pip,Yarn,com.spotify.client}
```
```bash
xcrun simctl delete unavailable
```

`brew cleanup` flags: bare = drop downloads >120 days old **and** old Cellar
versions · `-s` = also drop cached downloads for current versions · `--prune=all`
= ignore the age floor. Only non-cache deletion is old Cellar versions.

## Docker

```bash
docker system df                     # where the space is
docker builder prune -a -f           # safest reclaim, usually the biggest
```
```bash
# Untagged (repo:<none>) images — superseded layers from re-pulled tags
docker image ls --format '{{.ID}} {{.Repository}}:{{.Tag}}' | grep ':<none>$' | cut -d' ' -f1 | xargs docker rmi
```
```bash
# NEVER: docker volume prune   — named volumes read as "dangling" but hold data
docker volume ls -qf dangling=true   # inspect and remove individually instead
```
```bash
# Compaction only happens on a clean shutdown
osascript -e 'quit app "Docker"'
```

## Spotlight / cloud-sync loop

```bash
# 0 = properly excluded
mdfind -onlyin ~/Library/CloudStorage/GoogleDrive-<account> -count "kMDItemFSName == '*'"
```
Exclusions are GUI-only: System Settings → Spotlight → Search Privacy → **+**.
Add the **account folder**, not `My Drive`. ⌘⇧G to type a hidden path.

## Docker process triage

```bash
pgrep -fl 'Docker.app/Contents/MacOS/com.docker'   # backend tree
kill <top-level-pid>                                # SIGTERM first, wait 30s
pkill -9 -f 'Docker.app/Contents/MacOS/com.docker'  # last resort only
```
Leave `com.docker.vmnetd` alone (launchd-managed, respawns).

## This toolkit

```bash
make report        # full read-only diagnostic
make check         # guard once — exit 0 ok / 1 warn / 2 crit
make dry           # preview tier 1+2 reclaim
make clean-safe    # apply tier 1
make clean-more    # apply tier 1+2
make review        # tier 3 data candidates (never auto-deleted)
make docker        # docker report
make docker-clean  # prune + compact
make install-guard # launchd watchdog, every 2h
```
