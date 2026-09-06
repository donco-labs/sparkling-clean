#!/usr/bin/env zsh
# disk-report.zsh — read-only health + space diagnostic. Changes nothing.
#
#   ./bin/disk-report.zsh          full report
#   ./bin/disk-report.zsh --brief  headline numbers only

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
sc_require_macos

local brief=0
[[ ${1:-} == (--brief|-b) ]] && brief=1

# ============================================================ 1. THE NUMBER ==
sc_hdr "Disk"
local free=$(sc_free_bytes) total=$(sc_total_bytes) pct=$(sc_pct_free)
local used=$(( total - free ))

print -r -- "      container   $(sc_human $total)"
print -r -- "      used        $(sc_human $used)"
print -r -- "      free        $(sc_human $free)   (${pct}%)"

if   (( pct < SC_CRIT_PCT )); then sc_crit "below ${SC_CRIT_PCT}% free — swap cannot grow, jetsam kills likely"
elif (( pct < SC_WARN_PCT )); then sc_warn "below ${SC_WARN_PCT}% free — reclaim soon"
else                               sc_ok   "healthy headroom"
fi

sc_dim "      (df lies here: APFS rows share one container, df uses GiB not GB,"
sc_dim "       and Finder counts purgeable space that df does not.)"

# ========================================================== 2. SNAPSHOTS ====
sc_hdr "Local snapshots"
local snaps=$(sc_snapshot_count)
if (( snaps == 0 )); then
  sc_ok "none — deleted files return space immediately"
else
  sc_warn "$snaps local snapshot(s) pinning deleted blocks:"
  sc_snapshot_list | sed 's/^/        /'
  sc_info "reclaim.zsh thins these automatically; or: sudo tmutil thinlocalsnapshots / 999999999999 4"
fi

# ====================================================== 3. TIME MACHINE =====
sc_hdr "Time Machine"
if sc_tm_enabled; then
  sc_ok "automatic backups ON"
else
  sc_crit "automatic backups OFF — you are not being backed up"
  sc_info "re-enable: sudo tmutil enable"
fi

# Enabled != working. Age of the last COMPLETED backup is the real signal.
local tm_days
if tm_days=$(sc_tm_days_since_backup); then
  local when=$(sc_tm_last_backup_human)
  if   (( tm_days >= SC_TM_CRIT_D )); then
    sc_crit "last completed backup $when — ${tm_days} days ago"
    sc_info "a chain can fail silently for months; check Time Machine settings"
  elif (( tm_days >= SC_TM_WARN_D )); then
    sc_warn "last completed backup $when — ${tm_days} days ago"
  else
    sc_ok "last completed backup $when (${tm_days}d ago)"
  fi
else
  sc_warn "last completed backup: UNKNOWN (could not read TM preferences)"
fi

if sc_tm_running; then
  local prog=$(tmutil status 2>/dev/null | grep -oE 'Percent" = "[0-9.]+' | grep -oE '[0-9.]+$')
  sc_info "backup RUNNING now$( [[ -n $prog ]] && printf ' (%.1f%%)' $(( prog * 100 )) )"
fi

# ================================================ TM EXCLUSION HYGIENE ======
sc_hdr "Time Machine exclusions"
local -a unexcluded unex_rows
local unex_total=0 unex_files=0 cand sz fc
for cand in $SC_TM_EXCLUDE_CANDIDATES; do
  [[ -e $cand ]] || continue
  sc_tm_excluded $cand && continue
  sz=$(sc_size_of $cand); fc=$(sc_file_count $cand)
  sc_tm_worth_excluding $cand $sz $fc || continue
  unexcluded+=("$cand")
  # Rows are built here so size and file count are computed exactly once per
  # path -- find(1) over ~100k-entry trees is the expensive part of this report.
  unex_rows+=("${fc}"$'\t'"$(sc_human $sz)"$'\t'"${fc}"$'\t'"${cand/#$HOME/~}")
  (( unex_total += sz )); (( unex_files += fc ))
done

if (( ${#unexcluded} == 0 )); then
  sc_ok "no large or file-dense rebuildable directories are being backed up"
else
  sc_warn "$(sc_human $unex_total) / ${unex_files} files of rebuildable data in every backup:"
  # Sorted by FILE COUNT: on a network destination that is the real cost, both
  # when copying and again when the backup is later thinned file-by-file.
  print -rl -- $unex_rows | sort -rn -k1 \
    | awk -F'\t' '{printf "        %10s  %9s files  %s\n", $2, $3, $4}'
  sc_info "All are reconstructible from a registry, lockfile or re-download."
  sc_info "Review, then exclude (-p survives the folder being recreated):"
  local cmdline=""
  for cand in $unexcluded; do cmdline+=" ${(q)cand}" ; done
  print -r -- ""
  print -r -- "        sudo tmutil addexclusion -p${cmdline}"
  print -r -- ""
  sc_dim "        Verify:  tmutil isexcluded <path>"
  sc_dim "        Undo:    sudo tmutil removeexclusion -p <path>"
fi

(( brief )) && exit 0

# ========================================================== 4. MEMORY =======
sc_hdr "Memory pressure"
local ram_gb=$(( $(sysctl -n hw.memsize) / 1073741824 ))
print -r -- "      installed   ${ram_gb} GB"
top -l 1 -n 0 2>/dev/null | grep -E '^(PhysMem|VM:)' | sed 's/^/      /'
local swap=$(sysctl -n vm.swapusage 2>/dev/null)
print -r -- "      swap        ${swap}"
sc_dim "      Swap at 0 is fine on its own. Swap at 0 *while* the disk is full is"
sc_dim "      the failure mode: macOS cannot grow a swapfile, so tight RAM goes"
sc_dim "      straight to jetsam kills and pagein thrash."

# =================================================== 5. PRESSURE EVENTS =====
sc_hdr "Recent pressure events (last 14 days)"
local hits=$(find /Library/Logs/DiagnosticReports -maxdepth 1 -mtime -14 2>/dev/null \
             | grep -Ei 'jetsam|panic|watchdog|disk writes' | wc -l | tr -d ' ')
if (( hits == 0 )); then
  sc_ok "no jetsam / panic / watchdog / excessive-disk-write reports"
else
  sc_warn "$hits report(s):"
  ls -lt /Library/Logs/DiagnosticReports/ 2>/dev/null \
    | grep -Ei 'jetsam|panic|watchdog|disk writes' | head -8 \
    | awk '{print "        " $6, $7, $8, $9, $10, $11}'
fi

# ============================================================== 6. SMART ====
sc_hdr "SSD health"
if (( $+commands[smartctl] )); then
  { sudo smartctl -a /dev/disk0 2>/dev/null || true; } | grep -E \
    'Critical Warning|Available Spare|Percentage Used|Media and Data|Error Information Log Entries|Temperature:|Data Units' \
    | sed 's/^/      /'
  sc_dim "      Ignore any \"Read N entries from Error Information Log failed …"
  sc_dim "       GetLogPage failed … code=745\" line. Apple Silicon exposes only"
  sc_dim "       NVMe log page 0x02; smartctl asks for 0x01 anyway. Tool artifact."
else
  sc_info "smartctl not installed (brew install smartmontools)"
fi

# ======================================================== 7. BIG OFFENDERS ==
sc_hdr "Largest reclaim candidates"
local -a paths labels
paths=(
  ~/Library/Containers/com.docker.docker
  ~/Library/Application\ Support/com.apple.container
  ~/Library/Developer/Xcode/iOS\ DeviceSupport
  ~/Library/Developer/Xcode/DerivedData
  ~/Library/Caches/Homebrew
  ~/Library/Caches/JetBrains
  ~/Library/Caches/ms-playwright
  ~/Library/Caches/go-build
  ~/.gradle/caches
  ~/.ollama
  ~/.cache
  ~/Downloads
)
{
  for p in $paths; do
    local sz=$(sc_size_of $p)
    (( sz > 500000000 )) && printf '%d\t%s\t%s\n' $sz "$(sc_human $sz)" "${p/#$HOME/~}"
  done
} | sort -rn -k1 | awk -F'\t' '{printf "      %10s  %s\n", $2, $3}'

# ============================================================== 8. DOCKER ===
sc_hdr "Docker"
local raw=~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
if [[ -e $raw ]]; then
  print -r -- "      Docker.raw allocated  $(sc_size_h $raw)"
  sc_dim "      (ls -lh shows the sparse ceiling — often 460G — not real usage.)"
  if docker info >/dev/null 2>&1; then
    sc_ok "daemon responding"
    docker system df 2>/dev/null | sed 's/^/      /'
  else
    sc_info "daemon not running — start Docker Desktop to inspect/prune"
  fi
else
  sc_info "no Docker disk image"
fi

sc_hdr "Spotlight"
ps -Ao rss,comm 2>/dev/null | grep -Ei 'spotlight|corespotlight|mds_stores' | grep -v grep \
  | awk '{s+=$1} END {printf "      indexing footprint  %d MB\n", s/1024}'
for m in ~/Library/CloudStorage/*(N/); do
  local n=$(mdfind -onlyin "$m" -count "kMDItemFSName == '*'" 2>/dev/null)
  if [[ $n == 0 ]]; then sc_ok "excluded: ${m:t}"
  else sc_warn "INDEXED: ${m:t} ($n items) — consider Spotlight Privacy exclusion"
  fi
done

print

# =============================================================== VERDICT =====
# Same sc_run_health_checks the guard uses, so the report and the notification
# can never disagree about whether this machine is healthy.
sc_hdr "Verdict"
sc_run_health_checks
local c lvl name headline
for c in $SC_CHECKS; do
  lvl=${c%%$'\t'*}
  name=$(print -r -- $c | cut -f2)
  headline=$(print -r -- $c | cut -f3)
  case $lvl in
    (CRIT) printf '  %s  %-10s %s\n' "${SC_RED}CRIT${SC_RST}" $name "$headline" ;;
    (WARN) printf '  %s  %-10s %s\n' "${SC_YEL}WARN${SC_RST}" $name "$headline" ;;
    (*)    printf '  %s    %-10s %s\n' "${SC_GRN}OK${SC_RST}" $name "$headline" ;;
  esac
done
for n in $SC_NOTES; do sc_dim "  note  $n"; done
print
case $(sc_overall_level) in
  (CRIT) sc_crit "action needed" ;;
  (WARN) sc_warn "attention soon" ;;
  (*)    sc_ok   "healthy" ;;
esac
print
