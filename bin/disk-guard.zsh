#!/usr/bin/env zsh
# disk-guard.zsh — threshold watchdog. Read-only; notifies, never deletes.
#
#   ./bin/disk-guard.zsh            check once, notify if warranted
#   ./bin/disk-guard.zsh --force    notify regardless of de-dup window
#   ./bin/disk-guard.zsh --quiet    log only, no desktop notification
#
# Exit: 0 healthy · 1 warning · 2 critical   (usable from cron/launchd/CI)
#
# Thresholds via env (see lib/common.zsh): SC_WARN_PCT (15), SC_CRIT_PCT (10).
# Designed for launchd — see launchd/ and `make install-guard`.

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
sc_require_macos

local force=0 quiet=0
while (( $# )); do
  case $1 in
    --force) force=1 ;;
    --quiet) quiet=1 ;;
    -h|--help) sed -n '2,14p' ${0:A}; exit 0 ;;
  esac
  shift
done

local STATE=$SC_STATE_DIR/guard.state
mkdir -p $SC_STATE_DIR

local free=$(sc_free_bytes) pct=$(sc_pct_free)
local level=OK rc=0 msg=""

if   (( pct < SC_CRIT_PCT )); then
  level=CRIT; rc=2
  msg="Only $(sc_human $free) free (${pct}%). Swap cannot grow — expect freezes and app kills."
elif (( pct < SC_WARN_PCT )); then
  level=WARN; rc=1
  msg="$(sc_human $free) free (${pct}%). Reclaim before it bites."
else
  msg="$(sc_human $free) free (${pct}%)."
fi

# ---- secondary signals: these turn an OK into a WARN ------------------------
local -a notes

# Snapshots hoarding deleted blocks.
local snaps=$(sc_snapshot_count)
(( snaps >= 5 )) && notes+=("$snaps local snapshots pinning space")

# Backups silently left off — usually because a past cleanup paused them.
sc_tm_enabled || notes+=("Time Machine auto-backup is OFF")

# Enabled but not completing. This is the failure that hides for months: a full
# disk purges TM's reference snapshot, every backup then fails, nothing is
# surfaced. A running backup is not an excuse — only a COMPLETED one counts.
local tm_days
if tm_days=$(sc_tm_days_since_backup); then
  if (( tm_days >= SC_TM_CRIT_D )); then
    notes+=("no completed backup in ${tm_days} days")
    level=CRIT; rc=2
  elif (( tm_days >= SC_TM_WARN_D )); then
    notes+=("last backup ${tm_days}d ago")
  fi
else
  notes+=("backup age UNKNOWN")
fi

# The kernel's own distress signals in the last 3 days.
local recent=$(find /Library/Logs/DiagnosticReports -maxdepth 1 -mtime -3 2>/dev/null \
               | grep -Eic 'jetsam|panic|watchdog' | tr -d ' ')
(( recent > 0 )) && notes+=("$recent jetsam/panic report(s) in 3 days")

if (( ${#notes} )) && [[ $level == OK ]]; then level=WARN; rc=1; fi   # never demotes CRIT
(( ${#notes} )) && msg="$msg ${(j:; :)notes}."

# ---- log always -------------------------------------------------------------
sc_log "guard $level pct=$pct free=$free snaps=$snaps notes=${(j:,:)notes}"

# ---- de-dup: renotify only on escalation, or once per SC_RENOTIFY_H hours ---
# State holds TWO independent facts, and conflating them is a bug: the last level
# SEEN (drives change detection, always updated) and the last time we actually
# NOTIFIED (drives the repeat window, updated only when a notification fires).
# With one field, a --quiet run silently consumes a pending level change and the
# real notification never happens.
: ${SC_RENOTIFY_H:=12}
local prev_level="" prev_notify_ts=0
[[ -r $STATE ]] && IFS=$'\t' read -r prev_level prev_notify_ts < $STATE
local now=$(date +%s)

local should_notify=0
if   (( force ));                                                            then should_notify=1
elif [[ $level != OK && $level != $prev_level ]];                            then should_notify=1
elif [[ $level != OK ]] && (( now - prev_notify_ts > SC_RENOTIFY_H * 3600 )); then should_notify=1
fi

# A suppressed notification must not advance the notify clock, so a later
# non-quiet run still delivers it.
local notify_ts=$prev_notify_ts
(( should_notify && ! quiet )) && notify_ts=$now
printf '%s\t%s\n' $level $notify_ts > $STATE

# ---- output -----------------------------------------------------------------
case $level in
  CRIT) sc_crit "$msg" ;;
  WARN) sc_warn "$msg" ;;
  OK)   sc_ok   "$msg" ;;
esac

if (( should_notify && ! quiet )); then
  local title="Disk ${level}: ${pct}% free"
  if (( $+commands[terminal-notifier] )); then
    terminal-notifier -title "$title" -message "$msg" -group sparkling-clean 2>/dev/null
  else
    # Escape double quotes for the AppleScript string literal.
    osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" 2>/dev/null
  fi
  [[ $level == CRIT ]] && sc_info "run: $(dirname ${0:A})/reclaim.zsh --tier 2 --apply"
fi

exit $rc
