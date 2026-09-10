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

# Keep the newest local snapshot by default.
#
# `thinlocalsnapshots / 999999999999 4` is "free as much as possible, highest
# urgency", and it takes everything -- including the snapshot Time Machine uses
# as the baseline for its next incremental. Measured on the source host: 14
# snapshots to 0, 19 GB freed, and six hours later backupd logged
#
#   Failed to mount reference snapshot: com.apple.TimeMachine.2026-09-08-205130.local
#
# and had to establish what changed the expensive way. Older snapshots pin the
# most deleted data anyway, so keeping the newest costs a little space and saves
# the next backup real work. SC_THIN_ALL=1 restores the old behaviour.
: ${SC_THIN_ALL:=}

sc_thin_snapshots() {
  local -a snaps
  # Sorted, not trusting tmutil's output order: the names are
  # ...TimeMachine.YYYY-MM-DD-HHMMSS.local, so lexical order is chronological.
  snaps=( ${(f)"$(sc_snapshot_list | sort)"} )
  (( ${#snaps} )) || { sc_info "no local snapshots to thin"; return 0 }

  if [[ -n $SC_THIN_ALL ]]; then
    sc_info "thinning ALL local snapshots (external TM backups unaffected)…"
    sudo tmutil thinlocalsnapshots / 999999999999 4 2>&1 | sed 's/^/      /'
    return
  fi

  # Names look like com.apple.TimeMachine.2026-09-08-205130.local;
  # deletelocalsnapshots wants the bare YYYY-MM-DD-HHMMSS.
  local keep=${snaps[-1]} snap date
  sc_info "thinning $(( ${#snaps} - 1 )) local snapshot(s), keeping the newest"
  sc_info "keeping ${keep} — Time Machine's baseline for the next incremental"
  for snap in ${snaps[1,-2]}; do
    date=${${snap##*TimeMachine.}%.local}
    sudo tmutil deletelocalsnapshots "$date" 2>&1 | sed 's/^/      /'
  done
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

# Hours a chain may keep failing before the verdict goes critical. Deliberately
# much tighter than SC_TM_CRIT_D: age is a lagging signal and a failing attempt
# is a live one, so it does not get a week's grace.
: ${SC_TM_FAIL_CRIT_H:=12}
: ${SC_TM_STATE:=$SC_STATE_DIR/tm.state}

sc_tm_running() { tmutil status 2>/dev/null | grep -q 'Running = 1' }

# Percent complete of the running backup, or empty if none / unreadable.
#
# tmutil reports a FRACTION, and early in a run it uses scientific notation --
# "2.466504299824327e-06" is a real value from a backup ten seconds old. Matching
# it with [0-9.]+ truncates at the exponent, so 0.0002% renders as 246.7%: a
# progress display that reads "246%" on a backup that has barely started.
sc_tm_progress_pct() {
  local raw
  raw=$(tmutil status 2>/dev/null \
        | sed -nE 's/.*Percent"? = "([0-9.eE+-]+)".*/\1/p' | head -1)
  [[ -n $raw ]] || return 1
  printf '%.1f' $(( raw * 100 ))
}

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

# ---- did the last attempt actually SUCCEED? --------------------------------
# Age cannot see this, and that is the gap that lets a backup die quietly. The
# date above comes from SnapshotDates, which records completions only -- so a
# machine that attempts hourly and fails every single time simply freezes the
# number and keeps reporting "0d ago". By the time age drifts past SC_TM_WARN_D
# the destination is already days behind, and the guard was green throughout.
#
# RESULT is the outcome of the most recent attempt: 0 succeeded, non-zero
# failed. Same unprivileged `defaults read` the date comes from, which is the
# point -- the plist is not world-readable and `tmutil latestbackup` needs Full
# Disk Access, so under launchd this is the only route to the fact.
#
# One RESULT per configured destination, and the worst wins. On the single
# destination almost everyone has, that is exactly right; if you rotate between
# a NAS and a portable disk, read a failure as "at least one is failing", since
# the one sitting in a drawer will legitimately report stale.
sc_tm_last_result() {
  local r
  r=$(defaults read /Library/Preferences/com.apple.TimeMachine 2>/dev/null \
      | sed -nE 's/^[[:space:]]*RESULT[[:space:]]*=[[:space:]]*([0-9]+);.*/\1/p' \
      | sort -rn | head -1)
  [[ -n $r ]] || return 1
  print -r -- $r
}

# Only codes this toolkit has actually seen in
#   log show --predicate 'subsystem == "com.apple.TimeMachine"'
# are named. Everything else is reported as a bare number: a wrong cause sends
# you to the wrong subsystem, which is worse than an honest "look it up".
sc_tm_result_cause() {
  case ${1:-} in
    (26) print -r -- "the destination went away mid-copy (network dropped)" ;;
    (70) print -r -- "the backup disk image detached mid-copy" ;;
    (*)  print -r -- "backupd reported error ${1:-?}" ;;
  esac
}

# How long it has been failing. RESULT says the last attempt failed; it cannot
# say whether that started an hour ago or last week, and that difference is the
# whole verdict. The unified log holds the history, but `log show` over a
# multi-day window costs seconds -- unacceptable in a check the menu bar polls
# every ten minutes -- and it rolls off anyway. So record the first failing
# observation and keep it.
#
# Keyed on the last-success date, not just on failure: when a backup finally
# lands, SnapshotDates advances, the anchor changes and the stamp is discarded.
# A later, unrelated failure then starts its own clock instead of inheriting an
# old one and jumping straight to CRIT.
sc_tm_failing_since() {  # $1 = anchor (last-success epoch, or "none")
  local anchor=${1:-none} prev="" since=""
  [[ -r $SC_TM_STATE ]] && IFS=$'\t' read -r prev since < $SC_TM_STATE
  if [[ $prev != $anchor || -z $since ]]; then
    since=$(date +%s)
    mkdir -p ${SC_TM_STATE:h}
    printf '%s\t%s\n' "$anchor" "$since" > $SC_TM_STATE
  fi
  print -r -- $since
}

sc_tm_failing_clear() { rm -f $SC_TM_STATE 2>/dev/null }

# Hold the clock at now, keeping the anchor. Used while the destination is out
# of reach: time spent away must not accumulate toward the CRIT threshold, or
# coming home to a single failed attempt would escalate instantly.
sc_tm_failing_reset() {
  mkdir -p ${SC_TM_STATE:h}
  printf '%s\t%s\n' "${1:-none}" "$(date +%s)" > $SC_TM_STATE
}

# Is the destination reachable from where this machine is right now?
#   0 reachable · 1 not reachable · 2 cannot tell
#
# Time Machine reports a laptop that is simply on the wrong network with the
# same BACKUP_FAILED_DISCONNECTED_NETWORK (26) it uses for a link that died
# mid-copy. It does not distinguish "your NAS is at home and you are not" from
# "your NAS is here and the transfer keeps breaking", so ask the network.
#
# Only ever called when the last attempt FAILED, so the cost lands on the
# abnormal path: measured 0.02s when the destination answers, a 1s ceiling when
# it does not. A healthy machine never pays it.
sc_tm_destination_reachable() {
  local info host mp
  info=$(tmutil destinationinfo 2>/dev/null) || return 2
  [[ -n $info ]] || return 2

  # A local disk is reachable exactly when it is mounted.
  if print -r -- "$info" | grep -q '^Kind[[:space:]]*:[[:space:]]*Local'; then
    mp=$(print -r -- "$info" | sed -nE 's/^Mount Point[[:space:]]*:[[:space:]]*(.+)$/\1/p' | head -1)
    [[ -n $mp ]] || return 2
    [[ -d $mp ]] && return 0 || return 1
  fi

  # Network. The URL carries a Bonjour SERVICE name, not a host name --
  # "MyCloudEX2Ultra._smb._tcp.local." does not resolve; strip the service
  # labels off it to get "MyCloudEX2Ultra.local", which does.
  host=$(print -r -- "$info" | sed -nE 's|^URL[[:space:]]*:[[:space:]]*[a-z]+://([^/]+)/.*|\1|p' | head -1)
  host=${host##*@}                    # drop any user@
  host=${host/._smb._tcp/}
  host=${host/._afpovertcp._tcp/}
  host=${host%.}                      # trailing dot from the Bonjour name
  [[ -n $host ]] || return 2
  ping -c 1 -t 1 "$host" >/dev/null 2>&1 && return 0 || return 1
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
  # Claude Desktop's sandbox VM image. Same shape as Docker.raw: a handful of
  # huge files rewritten on every run, so each incremental re-copies a large
  # slice of 10 GB. The app recreates it; it holds runtime state, not documents.
  ~/Library/Application\ Support/Claude/vm_bundles
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

# ------------------------------------------------- kernel pressure events --
# Two traps here, both hit in practice:
#
# 1. DiagnosticReports contains a hidden `.contents.panic` metadata file. A bare
#    grep for "panic" counts it as a panic report, so the tally disagreed with
#    the list it printed (8 vs 7). Dotfiles are excluded.
#
# 2. Not all JetsamEvents mean the same thing. "per-process-limit" is one process
#    hitting its OWN ceiling -- routine, and not a sign of system trouble.
#    "vm-pageshortage" / "vm-thrashing" / "vm-compressor-*" are actual memory
#    exhaustion. Counting them together cries wolf over normal housekeeping.
sc_pressure_files() {  # $1 = days
  find /Library/Logs/DiagnosticReports -maxdepth 1 -mtime -${1:-3} \
       \! -name '.*' 2>/dev/null | grep -Ei 'jetsam|panic|watchdog|disk writes'
}

# Set by sc_pressure_events when a JetsamEvent could not be read and therefore
# could not be classified. Callers must surface this rather than treating an
# unreadable file as "not a memory event" -- a check that silently reads healthy
# when it cannot tell is worse than no check.
typeset -g SC_PRESSURE_UNKNOWN=0

sc_pressure_events() {  # $1 = days, $2 = "any" | "memory"
  local days=${1:-3} kind=${2:-any} f n=0
  if [[ $kind != memory ]]; then
    sc_pressure_files $days | grep -c . | tr -d ' '
    return
  fi
  SC_PRESSURE_UNKNOWN=0
  for f in ${(f)"$(sc_pressure_files $days)"}; do
    [[ $f == *JetsamEvent* ]] || continue
    # These are group-readable (_analyticsusers) on macOS 26, so no sudo -- and
    # deliberately NOT `sudo -n`, which fails whenever a password is required
    # and would silently make every event look benign.
    if ! grep -qE '"reason"' "$f" 2>/dev/null; then
      (( SC_PRESSURE_UNKNOWN++ )); continue
    fi
    grep -qE '"reason" : "(vm-pageshortage|vm-thrashing|vm-compressor)' "$f" 2>/dev/null && (( n++ ))
  done
  print -r -- $n
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

# Set when the Attempts row is failing only because the destination is out of
# reach. The row itself already says so, but a caller cannot tell that apart
# from any other WARN by reading the record, and the guard needs to: an expected
# weekday condition should not push a desktop notification. Matching on the
# headline string from outside would work until someone rewords it.
typeset -g SC_TM_AWAY=0

sc_check() { SC_CHECKS+=("${1}"$'\t'"${2}"$'\t'"${3}"$'\t'"${4:-$3}") }

# Accessors. The tab-separated record is an implementation detail; splitting it
# by hand at every call site duplicated the format five times and made the
# construct impossible to quote safely inside a CI `zsh -c '...'`.
sc_check_level()    { print -r -- "${1%%$'\t'*}" }
sc_check_name()     { print -r -- "$1" | cut -f2 }
sc_check_headline() { print -r -- "$1" | cut -f3 }
sc_check_detail()   { print -r -- "$1" | cut -f4 }
sc_note()  { SC_NOTES+=("$1") }

sc_level_rank() { case $1 in (CRIT) print -r -- 2 ;; (WARN) print -r -- 1 ;; (*) print -r -- 0 ;; esac }

# Worst check wins. Returns the whole record so callers can name the subsystem.
sc_worst_check() {
  # best starts below the lowest rank so an all-OK run still names a subject;
  # otherwise nothing is ever selected and callers get an empty record.
  local c best=-1 r winner=""
  for c in $SC_CHECKS; do
    r=$(sc_level_rank $(sc_check_level $c))
    (( r > best )) && { best=$r; winner=$c }
  done
  print -r -- $winner
}

sc_overall_level() {
  local w=$(sc_worst_check)
  [[ -n $w ]] && sc_check_level $w || print -r -- OK
}

# Populates SC_CHECKS / SC_NOTES. Single source of truth: the report and the
# guard must never disagree about whether this machine is healthy.
sc_run_health_checks() {
  SC_CHECKS=(); SC_NOTES=(); SC_TM_AWAY=0

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
  local tm_on=0
  if sc_tm_enabled; then
    tm_on=1
    sc_check OK Backups "enabled"
  else
    sc_check CRIT Backups "off" "Time Machine automatic backups are switched off — nothing is being backed up."
  fi

  # -- backup chain actually completing ----------------------------------
  local d
  if d=$(sc_tm_days_since_backup); then
    if   (( d >= SC_TM_CRIT_D )); then
      sc_check CRIT Backup "${d} days" "No completed backup in ${d} days. The last one finished $(sc_tm_last_backup_human)."
    elif (( d >= SC_TM_WARN_D )); then
      sc_check WARN Backup "${d} days" "Last completed backup was ${d} days ago."
    else
      sc_check OK Backup "${d}d ago" "Last completed backup $(sc_tm_last_backup_human)."
    fi
  else
    sc_check WARN Backup "age unknown" "Could not read the last backup date from Time Machine preferences, so this is unverified rather than healthy."
  fi

  # -- are those attempts succeeding -------------------------------------
  # Age and outcome are different facts and get different rows. A chain can be
  # "0d ago" and failing every hour -- that is the normal shape of this fault,
  # not an edge case -- so folding the two together would let the healthy number
  # mask the broken one. Skipped when Time Machine is off: the CRIT above
  # already says nothing is being backed up, and a stale RESULT adds no signal.
  if (( tm_on )); then
    local res
    if res=$(sc_tm_last_result); then
      if (( res == 0 )); then
        sc_tm_failing_clear
        sc_check OK Attempts "last ok"
      else
        local anchor since hours cause reach
        anchor=$(sc_tm_last_backup_epoch) || anchor=none
        cause=$(sc_tm_result_cause $res)
        sc_tm_destination_reachable; reach=$?

        # Being away from the destination is not a fault. A laptop on a
        # different network cannot reach the NAS at home, and Time Machine
        # reports that with the same code 26 a genuine mid-copy drop produces.
        #
        # It stays a WARN, because backups are genuinely not happening and a
        # check that reads OK because you are travelling is the same lie this
        # toolkit exists to catch. What it does not do is escalate: the Backup
        # age check above already owns "away too long", and duplicating that
        # here would put two rows at CRIT for one condition.
        #
        # Only a definite "not reachable" (1) suppresses escalation. A probe
        # that cannot tell (2) takes the normal path -- never go quiet on
        # uncertainty.
        if (( reach == 1 )); then
          # Hold the clock, or coming home to one failed attempt would escalate
          # instantly on time that was only ever spent out of range.
          sc_tm_failing_reset $anchor
          SC_TM_AWAY=1
          sc_check WARN Attempts "destination away" \
            "The destination is not reachable from this network, so nothing can be backed up (attempts report code ${res}). Expected while you are away; it should clear when you are back on its network. Last completed backup $(sc_tm_last_backup_human) — if you stay away, the Backup row above is what escalates."
        else
          since=$(sc_tm_failing_since $anchor)
          hours=$(( ( $(date +%s) - since ) / 3600 ))
          if (( hours >= SC_TM_FAIL_CRIT_H )); then
            sc_check CRIT Attempts "failing ${hours}h" \
              "Every backup attempt has failed for ${hours}h — ${cause} (code ${res}). The destination is reachable, so this is not distance: backups are starting on schedule and none are landing. The last one that completed was $(sc_tm_last_backup_human)."
          else
            sc_check WARN Attempts "failing" \
              "The most recent backup attempt failed — ${cause} (code ${res}). The last completed backup was $(sc_tm_last_backup_human), so the age above is still plausible; it will stay that way while the chain rots."
          fi
        fi
      fi
    else
      sc_check WARN Attempts "unknown" \
        "Could not read the outcome of the last backup attempt from Time Machine preferences, so this is unverified rather than healthy."
    fi
  fi

  # -- snapshots holding space -------------------------------------------
  # Headline stays a bare count: it is rendered as "Snapshots: 5" in the menu
  # bar, where every character costs. "Pinning" was also invented jargon.
  local n=$(sc_snapshot_count)
  if (( n >= 5 )); then
    sc_check WARN Snapshots "${n}" \
      "${n} local snapshots are still holding space from files you deleted. Until they are thinned, deleting more will not free anything."
  else
    sc_check OK Snapshots "${n}"
  fi

  # -- historical context, never escalates -------------------------------
  local n_mem=$(sc_pressure_events 3 memory) n_any=$(sc_pressure_events 3 any)
  if (( n_mem > 0 )); then
    sc_note "${n_mem} memory-exhaustion event(s) in the last 3 days (past events; if it recurs, look at RAM not disk)"
  elif (( SC_PRESSURE_UNKNOWN > 0 )); then
    sc_note "${SC_PRESSURE_UNKNOWN} jetsam event(s) in the last 3 days whose reason could not be read"
  elif (( n_any > 0 )); then
    sc_note "${n_any} kernel report(s) in the last 3 days — none from memory exhaustion (routine per-process limits)"
  fi
}

# --------------------------------------------------------------- watchlist --
# Directories worth watching for creep. A SUPERSET of the exclusion candidates:
# it includes user data like ~/Downloads that should be watched but must never
# be suggested for exclusion, so the two lists stay separate on purpose.
typeset -ga SC_WATCH_PATHS=(
  $SC_TM_EXCLUDE_CANDIDATES
  ~/Downloads
  ~/models
  ~/.gradle
  ~/Library/Developer/Xcode
)

# Sizing this set costs ~10s of directory walking — fine twice a day, absurd
# every ten minutes. A menu bar item that generated sustained metadata I/O would
# be causing the exact problem this toolkit exists to detect. So: cache it, and
# refresh only when stale. Creep happens over days; half-day-old numbers are
# entirely adequate for spotting it.
: ${SC_SIZES_CACHE:=$SC_STATE_DIR/sizes.tsv}
: ${SC_SIZES_MAX_AGE_H:=12}

sc_sizes_age_hours() {
  [[ -r $SC_SIZES_CACHE ]] || { print -r -- 9999; return }
  local m=$(stat -f %m "$SC_SIZES_CACHE" 2>/dev/null)
  [[ -n $m ]] && print -r -- $(( ( $(date +%s) - m ) / 3600 )) || print -r -- 9999
}

sc_sizes_stale() { (( $(sc_sizes_age_hours) >= SC_SIZES_MAX_AGE_H )) }

# Writes "<bytes>\t<path>" for everything that exists, biggest first.
sc_sizes_refresh() {
  mkdir -p ${SC_SIZES_CACHE:h}
  local tmp=${SC_SIZES_CACHE}.$$
  local c sz

  # Drop any watched path that lives inside another one — ~/.gradle/caches under
  # ~/.gradle, DerivedData under ~/Library/Developer/Xcode. Without this the
  # child is counted twice in the total and both rows appear in the list, which
  # reads as though the space is in two places.
  local -a keep=()
  local a b nested
  for a in ${(o)SC_WATCH_PATHS}; do
    nested=0
    for b in $keep; do [[ $a == ${b}/* ]] && { nested=1; break } ; done
    (( nested )) || keep+=($a)
  done

  for c in $keep; do
    [[ -e $c ]] || continue
    sz=$(sc_size_of $c)
    (( sz > 0 )) && printf '%s\t%s\n' "$sz" "$c"
  done | sort -rn > $tmp
  mv -f $tmp $SC_SIZES_CACHE
}

sc_sizes_read() { [[ -r $SC_SIZES_CACHE ]] && cat $SC_SIZES_CACHE }

# ----------------------------------------------------------------- trends --
# The guard logs free bytes on every run, so a point-in-time check becomes a
# trend for free. This is the view that would have caught the original incident
# months earlier: not "you are at 93%", but "you have been falling for weeks".

# Free-space samples, oldest first, one per line: "<epoch> <bytes>".
sc_free_history() {  # $1 = max samples (default 24)
  local max=${1:-24}
  [[ -r $SC_LOG ]] || return 1
  grep -oE '^[0-9-]+T[0-9:]+[+-][0-9]+ guard [A-Z]+ pct=[0-9]+ free=[0-9]+' $SC_LOG 2>/dev/null \
    | sed -E 's/^([0-9-]+)T([0-9:]+)[+-][0-9]+ .*free=([0-9]+)$/\1 \2 \3/' \
    | while read -r d t b; do
        print -r -- "$(date -j -f '%Y-%m-%d %H:%M:%S' "$d $t" '+%s' 2>/dev/null) $b"
      done | grep -E '^[0-9]+ [0-9]+$' | tail -$max
}

# Unicode block sparkline. Scaled to the observed range rather than to zero —
# the question is "which way is this moving", and a 0-500 GB axis flattens every
# real change into a straight line.
sc_sparkline() {  # reads "<epoch> <bytes>" lines on stdin
  local -a v; local l
  while read -r _ b; do v+=($b); done
  (( ${#v} < 2 )) && return 1
  local min=${v[1]} max=${v[1]} x
  for x in $v; do (( x < min )) && min=$x; (( x > max )) && max=$x; done
  local span=$(( max - min ))
  local -a blocks=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
  local out=""
  for x in $v; do
    if (( span == 0 )); then out+="▄"
    else out+=${blocks[$(( x == max ? 8 : (x - min) * 8 / span + 1 ))]}
    fi
  done
  print -r -- "$out"
}

# Human delta between the oldest and newest sample, with the window it spans.
sc_free_delta() {  # reads "<epoch> <bytes>" lines on stdin
  local -a e b; local ts by
  while read -r ts by; do e+=($ts); b+=($by); done
  (( ${#b} < 2 )) && return 1
  local d=$(( b[-1] - b[1] )) hours=$(( (e[-1] - e[1]) / 3600 ))
  local sign="+"; (( d < 0 )) && { sign="−"; d=$(( -d )) }
  # Each branch carries its own preposition. Appending a bare window to a fixed
  # "over " produced "−4.6 GB over under an hour" for any sample under an hour.
  local window
  if   (( hours >= 48 )); then window="over $(( hours / 24 ))d"
  elif (( hours >= 1  )); then window="over ${hours}h"
  else                         window="in under an hour"
  fi
  print -r -- "${sign}$(sc_human $d) ${window}"
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
