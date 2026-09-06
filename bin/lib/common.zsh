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
