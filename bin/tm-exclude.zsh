#!/usr/bin/env zsh
# tm-exclude.zsh — apply the codified Time Machine exclusion list. DRY-RUN BY DEFAULT.
#
#   ./bin/tm-exclude.zsh            show what would change
#   ./bin/tm-exclude.zsh --apply    exclude every candidate that exists
#   ./bin/tm-exclude.zsh --status   applied / not-applied table
#   ./bin/tm-exclude.zsh --undo     remove exclusions this list added
#
# The candidate list lives in lib/common.zsh (SC_TM_EXCLUDE_CANDIDATES) and is
# versioned, so a rebuilt machine gets the same policy with one command.
#
# NOTE: tmutil addexclusion needs Full Disk Access. Run this from a terminal that
# has it (System Settings → Privacy & Security → Full Disk Access).
#
# Why this applies to EVERY existing candidate, not just the ones disk-report
# flags: the report's size/count thresholds exist to surface offenders worth your
# attention. They are the wrong basis for policy. A freshly-emptied DerivedData is
# under threshold today and back to gigabytes next week — on this machine exactly
# that happened, and the two Xcode directories silently stayed in every backup.

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
sc_require_macos

local mode=dry
while (( $# )); do
  case $1 in
    --apply)   mode=apply ;;
    --status)  mode=status ;;
    --undo)    mode=undo ;;
    -h|--help) sed -n '2,20p' ${0:A}; exit 0 ;;
    *) print -ru2 -- "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

local -a present missing already
local c
for c in $SC_TM_EXCLUDE_CANDIDATES; do
  if [[ ! -e $c ]];        then missing+=("$c")
  elif sc_tm_excluded $c;  then already+=("$c")
  else                          present+=("$c")
  fi
done

if [[ $mode == status ]]; then
  sc_hdr "Time Machine exclusion policy"
  for c in $already; do sc_ok   "${c/#$HOME/~}" ; done
  for c in $present; do sc_warn "${c/#$HOME/~}  — exists, NOT excluded" ; done
  for c in $missing; do sc_dim  "      absent   ${c/#$HOME/~}" ; done
  print
  print -r -- "      ${#already} applied · ${#present} pending · ${#missing} absent (of ${#SC_TM_EXCLUDE_CANDIDATES})"
  print
  exit $(( ${#present} > 0 ))
fi

if [[ $mode == undo ]]; then
  sc_hdr "Removing exclusions"
  (( ${#already} == 0 )) && { sc_ok "nothing to remove"; exit 0 }
  for c in $already; do print -r -- "        ${c/#$HOME/~}"; done
  print -r -- ""
  print -r -- "        sudo tmutil removeexclusion -p${(j: :)${(q)already/#/ }}"
  print
  sc_info "Review, then run the line above. This script does not remove exclusions for you."
  exit 0
fi

sc_hdr "Time Machine exclusions"
sc_info "${#already} already applied · ${#missing} absent (will be caught on a later run)"

if (( ${#present} == 0 )); then
  sc_ok "every existing candidate is already excluded"
  exit 0
fi

print -r -- ""
local total=0 fc n=0
for c in $present; do
  n=$(sc_file_count $c); (( total += $(sc_size_of $c) ))
  printf '  %10s  %9s files  %s\n' "$(sc_size_h $c)" "$n" "${c/#$HOME/~}"
done
print -r -- ""

local cmdline=""
for c in $present; do cmdline+=" ${(q)c}" ; done

if [[ $mode == apply ]]; then
  sc_info "applying ${#present} exclusion(s) — sudo will prompt…"
  if sudo tmutil addexclusion -p ${present}; then
    print
    local failed=0
    for c in $present; do sc_tm_excluded $c || { sc_crit "FAILED: ${c/#$HOME/~}"; (( failed++ )) } ; done
    (( failed == 0 )) && sc_ok "all ${#present} applied and verified"
    sc_log "tm-exclude applied=${#present} failed=${failed}"
    exit $(( failed > 0 ))
  else
    sc_crit "tmutil failed — does this terminal have Full Disk Access?"
    exit 1
  fi
fi

sc_warn "$(sc_human $total) across ${#present} path(s) would be excluded. Dry run — nothing changed."
sc_info "Apply with:  ${0:t} --apply"
sc_info "Or by hand:"
print -r -- ""
print -r -- "        sudo tmutil addexclusion -p${cmdline}"
print
