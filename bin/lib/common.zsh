#!/usr/bin/env zsh
# common.zsh — shared helpers for sparkling-clean
# Sourced by every bin/*.zsh script. Not executable on its own.

emulate -L zsh
# NOTE: deliberately NOT err_return/pipe_fail. Diagnostic tools routinely exit
# non-zero on benign conditions (smartctl=4 on the Apple GetLogPage artifact,
# docker when stopped, du on unreadable dirs). Handle errors explicitly instead.
setopt no_err_return no_unset

# ---------------------------------------------------------------- constants --
: ${SC_DATA_VOLUME:=/System/Volumes/Data}
: ${SC_STATE_DIR:=$HOME/.local/state/sparkling-clean}
: ${SC_LOG:=$SC_STATE_DIR/sparkling-clean.log}

# Thresholds (percent of APFS container free). Override via env.
: ${SC_WARN_PCT:=15}
: ${SC_CRIT_PCT:=10}

# ------------------------------------------------------------------- colour --
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  SC_RED=$'\e[31m'; SC_YEL=$'\e[33m'; SC_GRN=$'\e[32m'
  SC_DIM=$'\e[2m';  SC_BLD=$'\e[1m';  SC_RST=$'\e[0m'
else
  SC_RED=''; SC_YEL=''; SC_GRN=''; SC_DIM=''; SC_BLD=''; SC_RST=''
fi

sc_hdr()  { print -r -- ""; print -r -- "${SC_BLD}== $* ==${SC_RST}"; }
sc_ok()   { print -r -- "${SC_GRN}OK${SC_RST}    $*"; }
sc_warn() { print -r -- "${SC_YEL}WARN${SC_RST}  $*"; }
sc_crit() { print -r -- "${SC_RED}CRIT${SC_RST}  $*"; }
sc_info() { print -r -- "      $*"; }
sc_dim()  { print -r -- "${SC_DIM}$*${SC_RST}"; }

sc_log() {
  mkdir -p ${SC_LOG:h}
  print -r -- "$(date '+%Y-%m-%dT%H:%M:%S%z') $*" >> $SC_LOG
}

# --------------------------------------------------------------- disk truth --
# The ONLY number that is not lying to you.
#
# Why not `df`?
#   * APFS volumes share one container: `Size` and `Avail` are container-wide
#     and identical on every row. Only `Used` is per-volume. Never sum rows.
#   * `df -h` reports GiB (1024^3); diskutil and Finder report GB (1000^3).
#   * Finder counts "purgeable" (snapshots, evictable caches) as free. df does not.
sc_container_bytes() {  # $1 = "Free" | "Total"
  local field=${1:?Free|Total}
  diskutil info $SC_DATA_VOLUME 2>/dev/null \
    | grep "Container ${field} Space" \
    | sed -E 's/.*\(([0-9]+) Bytes\).*/\1/'
}

sc_free_bytes()  { sc_container_bytes Free }
sc_total_bytes() { sc_container_bytes Total }

sc_pct_free() {
  local free=$(sc_free_bytes) total=$(sc_total_bytes)
  [[ -n $free && -n $total && $total -gt 0 ]] || { print -r -- 0; return }
  printf '%d' $(( free * 100 / total ))
}

sc_human() {  # bytes -> human (GB, base-10, to match diskutil/Finder)
  local b=${1:-0}
  if   (( b >= 1000000000 )); then printf '%.1f GB' $(( b / 1000000000.0 ))
  elif (( b >= 1000000    )); then printf '%.0f MB' $(( b / 1000000.0 ))
  else                             printf '%d B' $b
  fi
}

# `du` reports ALLOCATED blocks; `ls -lh` reports LOGICAL size. For sparse files
# (Docker.raw is the classic) those differ by tens of GB. Always du.
sc_size_of() {  # path -> allocated bytes (0 if missing)
  [[ -e $1 ]] || { print -r -- 0; return }
  du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}'
}

sc_size_h() { sc_human $(sc_size_of "$1") }

# ---------------------------------------------------------------- snapshots --
# Deleting files that a local Time Machine snapshot references frees NOTHING
# until the snapshot is thinned. Always thin after a reclaim pass.
sc_snapshot_list()  { tmutil listlocalsnapshots / 2>/dev/null | grep -v '^Snapshots for' }
sc_snapshot_count() { sc_snapshot_list | grep -c . }

sc_thin_snapshots() {
  sc_info "thinning local snapshots (external TM backups unaffected)…"
  sudo tmutil thinlocalsnapshots / 999999999999 4 2>&1 | sed 's/^/      /'
}

# ----------------------------------------------------------- Time Machine --
# "Is TM enabled" is NOT the same question as "is TM working". A backup chain can
# fail silently for months: if the disk fills, macOS purges the local snapshot TM
# uses as its incremental reference, the reference goes "(dataless)", and every
# subsequent backup fails with nothing surfaced to the user. That is exactly how
# this host went 2026-05-23 -> 2026-09-05 with no completed backup. Check AGE.
#
# Source: /Library/Preferences/com.apple.TimeMachine.plist is world-readable, so
# this works unprivileged under launchd. `tmutil latestbackup` does NOT -- it
# needs Full Disk Access, which a LaunchAgent will not have.
: ${SC_TM_WARN_D:=2}
: ${SC_TM_CRIT_D:=7}

sc_tm_running() { tmutil status 2>/dev/null | grep -q 'Running = 1' }

# Epoch seconds of the last COMPLETED backup. Returns 1 if undeterminable --
# callers must report "unknown", never assume healthy. A check that silently
# reads OK when it cannot tell is worse than no check at all.
sc_tm_last_backup_epoch() {
  local d
  d=$(defaults read /Library/Preferences/com.apple.TimeMachine 2>/dev/null \
      | sed -n '/SnapshotDates/,/);/p' \
      | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \+[0-9]{4}' \
      | tail -1)
  [[ -n $d ]] || return 1
  date -j -f '%Y-%m-%d %H:%M:%S %z' "$d" '+%s' 2>/dev/null
}

sc_tm_days_since_backup() {
  local e
  e=$(sc_tm_last_backup_epoch) || return 1
  [[ -n $e ]] || return 1
  print -r -- $(( ( $(date +%s) - e ) / 86400 ))
}

sc_tm_last_backup_human() {
  local e
  e=$(sc_tm_last_backup_epoch) || { print -r -- "unknown"; return 1 }
  date -r $e '+%Y-%m-%d %H:%M'
}

sc_tm_enabled() {
  local v=$(defaults read /Library/Preferences/com.apple.TimeMachine AutoBackup 2>/dev/null)
  [[ $v == 1 ]]
}

# Pause TM so it cannot mint a fresh snapshot mid-reclaim and re-pin the blocks
# we are deleting. The trap guarantees it comes back on — leaving a machine
# without backups is far worse than a re-pinned cache.
SC_TM_WAS_ON=0
sc_tm_pause() {
  if sc_tm_enabled; then
    SC_TM_WAS_ON=1
    sc_info "pausing Time Machine for the duration…"
    sudo tmutil disable
    trap 'sc_tm_restore' EXIT INT TERM
  fi
}
sc_tm_restore() {
  if (( SC_TM_WAS_ON )); then
    SC_TM_WAS_ON=0
    print -r -- "      re-enabling Time Machine…"
    sudo tmutil enable
  fi
}

# ------------------------------------------------- Time Machine exclusions --
# A backup can be technically healthy and still be mostly garbage. Container
# images, package caches and toolchains are all reconstructible from a registry
# or a lockfile, but Time Machine copies them like anything else -- inflating
# both the byte count and, worse, the FILE count that dominates a network
# backup's cost. On the host this came from, ~60 GB of exactly this was going to
# a NAS over Wi-Fi, with backupd burning 173% CPU at 7.5 files/sec.
#
# Docker.raw deserves special mention: one 22 GB sparse image, rewritten on every
# container run, so every incremental re-copies large chunks of it.
#
# Only genuinely reconstructible paths belong here. Anything a user might have
# hand-curated (documents, Downloads, photo libraries) must never be suggested.
typeset -ga SC_TM_EXCLUDE_CANDIDATES=(
  ~/Library/Containers/com.docker.docker
  ~/Library/Application\ Support/com.apple.container
  ~/Library/Containers/com.inferencer
  ~/Library/Developer/Xcode/DerivedData
  ~/Library/Developer/Xcode/iOS\ DeviceSupport
  ~/Library/Caches
  ~/.cache
  ~/.gradle/caches
  ~/.npm
  ~/.ollama
  ~/.rustup
  ~/.konan
  ~/.sdkman
  ~/.pub-cache
  ~/fvm
  ~/go/pkg
  ~/Library/pnpm
  ~/.vscode/extensions
  ~/.cargo/registry
  ~/.m2/repository
)

# tmutil isexcluded prints "[Excluded]  /path" or "[Included]  /path".
# Works unprivileged, so this is safe from a LaunchAgent.
sc_tm_excluded() { tmutil isexcluded "$1" 2>/dev/null | grep -q '^\[Excluded\]' }

# On a network destination the FILE COUNT dominates, not the byte count: every
# file is a separate round-trip, on the way in and again when the backup is
# thinned. Measured on the source host: ~/.ollama is 6.6 GB in 29 files (cheap,
# big sequential blobs) while ~/.pub-cache is 1.2 GB in 61,296 files -- five
# times smaller, roughly two thousand times more round-trips. Filtering on size
# alone made ~/.cargo (233 MB, 15,705 files) and ~/Library/pnpm (440 MB, 22,685)
# invisible.
: ${SC_TM_MIN_BYTES:=500000000}
: ${SC_TM_MIN_FILES:=10000}

sc_file_count() { [[ -e $1 ]] && find "$1" 2>/dev/null | wc -l | tr -d ' ' || print -r -- 0 }

# Flag on EITHER axis.
sc_tm_worth_excluding() {  # $1 path, $2 bytes, $3 files
  (( $2 >= SC_TM_MIN_BYTES || $3 >= SC_TM_MIN_FILES ))
}

# ------------------------------------------------------------ health model --
# Each check yields its OWN verdict. Nothing mutates a shared level, and no
# check inherits another's prose -- the original design had every alert titled
# "Disk" and phrased in disk language, so a 61-day-stale backup chain announced
# itself as "Disk CRIT: 22% free" on a machine with 121 GB spare.
#
# Two tiers, deliberately distinct:
#   CHECKS  current conditions. Escalate, notify, set the exit code.
#   NOTES   historical context. Never escalate, never notify.
#
# Jetsam/panic reports live in NOTES on purpose. They are evidence that
# something already happened, not that anything is wrong now -- so after you fix
# the cause they would otherwise hold the guard at WARN for days, which is
# exactly when a monitor most needs to go quiet. If the cause is still live,
# disk% or backup age catches it as a current condition.

typeset -ga SC_CHECKS=()   # level \t name \t headline \t detail
typeset -ga SC_NOTES=()

sc_check() { SC_CHECKS+=("${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4:-$3}") }
sc_note()  { SC_NOTES+=("$1") }

sc_level_rank() { case $1 in (CRIT) print -r -- 2 ;; (WARN) print -r -- 1 ;; (*) print -r -- 0 ;; esac }

# Worst check wins. Returns the whole record so callers can name the subsystem.
sc_worst_check() {
  # best starts below the lowest rank so an all-OK run still names a subject;
  # otherwise nothing is ever selected and callers get an empty record.
  local c best=-1 r winner=""
  for c in $SC_CHECKS; do
    r=$(sc_level_rank ${c%%$'\t'*})
    (( r > best )) && { best=$r; winner=$c }
  done
  print -r -- $winner
}

sc_overall_level() {
  local w=$(sc_worst_check)
  [[ -n $w ]] && print -r -- ${w%%$'\t'*} || print -r -- OK
}

# Populates SC_CHECKS / SC_NOTES. Single source of truth: the report and the
# guard must never disagree about whether this machine is healthy.
sc_run_health_checks() {
  SC_CHECKS=(); SC_NOTES=()

  # -- disk --------------------------------------------------------------
  local free=$(sc_free_bytes) pct=$(sc_pct_free)
  if   (( pct < SC_CRIT_PCT )); then
    sc_check CRIT Disk "${pct}% free" \
      "Only $(sc_human $free) free (${pct}%). Swap cannot grow — expect freezes and app kills."
  elif (( pct < SC_WARN_PCT )); then
    sc_check WARN Disk "${pct}% free" "$(sc_human $free) free (${pct}%). Reclaim before it bites."
  else
    sc_check OK   Disk "${pct}% free" "$(sc_human $free) free (${pct}%)."
  fi

  # -- backups on at all -------------------------------------------------
  if sc_tm_enabled; then
    sc_check OK Backups "enabled"
  else
    sc_check CRIT Backups "auto-backup OFF" "Time Machine automatic backups are OFF — nothing is being backed up."
  fi

  # -- backup chain actually completing ----------------------------------
  local d
  if d=$(sc_tm_days_since_backup); then
    if   (( d >= SC_TM_CRIT_D )); then
      sc_check CRIT Backup "${d} days stale" "No completed backup in ${d} days (last: $(sc_tm_last_backup_human))."
    elif (( d >= SC_TM_WARN_D )); then
      sc_check WARN Backup "${d} days stale" "Last completed backup ${d} days ago."
    else
      sc_check OK Backup "${d}d ago" "Last completed backup $(sc_tm_last_backup_human)."
    fi
  else
    sc_check WARN Backup "age unknown" "Could not determine last backup age from Time Machine preferences."
  fi

  # -- snapshots pinning space -------------------------------------------
  local n=$(sc_snapshot_count)
  if (( n >= 5 )); then
    sc_check WARN Snapshots "${n} pinning space" "${n} local snapshots are holding deleted blocks. Thin them."
  else
    sc_check OK Snapshots "${n}"
  fi

  # -- historical context, never escalates -------------------------------
  local recent=$(find /Library/Logs/DiagnosticReports -maxdepth 1 -mtime -3 2>/dev/null \
                 | grep -Eic 'jetsam|panic|watchdog' | tr -d ' ')
  (( recent > 0 )) && sc_note "${recent} jetsam/panic report(s) in the last 3 days (past events, not a current fault)"
}

# --------------------------------------------------------------- execution --
# Every destructive helper routes through here. SC_APPLY=0 (the default) prints
# what would happen and touches nothing.
: ${SC_APPLY:=0}

sc_run() {  # sc_run <label> <command…>
  local label=$1; shift
  if (( SC_APPLY )); then
    print -r -- "  ${SC_GRN}RUN${SC_RST}  $label"
    "$@" >/dev/null 2>&1 || print -r -- "       ${SC_YEL}(non-zero exit, continuing)${SC_RST}"
  else
    print -r -- "  ${SC_DIM}DRY${SC_RST}  $label"
  fi
}

sc_rm() {  # sc_rm <label> <path…> — reports reclaimable size, then removes
  local label=$1; shift
  local total=0 p
  for p in "$@"; do (( total += $(sc_size_of $p) )); done
  (( total == 0 )) && return 0
  if (( SC_APPLY )); then
    print -r -- "  ${SC_GRN}RUN${SC_RST}  $label  ($(sc_human $total))"
    rm -rf -- "$@" 2>/dev/null || true
  else
    print -r -- "  ${SC_DIM}DRY${SC_RST}  $label  ($(sc_human $total))"
  fi
  print -r -- $total > /dev/null
}

sc_require_macos() {
  [[ $(uname -s) == Darwin ]] || { print -ru2 -- "sparkling-clean: macOS only"; exit 1 }
}
