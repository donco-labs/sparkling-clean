#!/usr/bin/env zsh
# reclaim.zsh — tiered disk reclamation. DRY-RUN BY DEFAULT.
#
#   ./bin/reclaim.zsh                  show what tier 1 would free (nothing removed)
#   ./bin/reclaim.zsh --apply          actually reclaim tier 1
#   ./bin/reclaim.zsh --tier 2 --apply tier 1 + 2
#   ./bin/reclaim.zsh --tier 3         REPORT ONLY — tier 3 is never automated
#
# Tiers
#   1  caches that regenerate with no user action. No judgment required.
#   2  caches that cost a re-download or a rebuild. Safe, but you will notice.
#   3  data. NEVER deleted by this script — reported so you can decide.

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
sc_require_macos

local tier=1
while (( $# )); do
  case $1 in
    --apply)      SC_APPLY=1 ;;
    --tier|-t)    shift; tier=$1 ;;
    --no-thin)    SC_NO_THIN=1 ;;
    -h|--help)    sed -n '2,20p' ${0:A}; exit 0 ;;
    *) print -ru2 -- "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

local before=$(sc_free_bytes)
print -r -- "${SC_BLD}sparkling-clean reclaim${SC_RST}  tier=$tier  mode=$( (( SC_APPLY )) && print APPLY || print DRY-RUN )"
print -r -- "free before: $(sc_human $before)  ($(sc_pct_free)%)"

# Refuse to start on top of a running backup. sc_tm_pause runs `tmutil disable`,
# which does not wait politely — it stops the backup in progress. On a machine
# whose chain is already struggling, silently killing the run you have been
# waiting on is a far worse outcome than reclaiming ten minutes later.
if (( SC_APPLY )) && sc_tm_running && [[ -z ${SC_ALLOW_DURING_BACKUP:-} ]]; then
  sc_crit "a backup is running — refusing to reclaim"
  sc_info "This pauses Time Machine before it starts, which aborts the backup in"
  sc_info "progress. Your existing backups are not at risk; the run in flight is."
  sc_info "Wait for it to finish, or set SC_ALLOW_DURING_BACKUP=1 to override."
  exit 2
fi

# Pause TM so a fresh snapshot cannot re-pin what we delete. Trap restores it.
(( SC_APPLY )) && sc_tm_pause

# =================================================================== TIER 1 ==
sc_hdr "Tier 1 — regenerating caches (no user action to restore)"

# Xcode. DeviceSupport is usually the single biggest safe win; it is re-created
# automatically the next time you attach that iOS device.
sc_rm "Xcode iOS DeviceSupport"  ~/Library/Developer/Xcode/iOS\ DeviceSupport/*(N)
sc_rm "Xcode DerivedData"        ~/Library/Developer/Xcode/DerivedData/*(N)
sc_rm "Xcode Archives (>90d)"    ~/Library/Developer/Xcode/Archives/*(Nm+90)

# Homebrew keeps every downloaded bottle plus its own vendored ruby per upgrade.
if (( $+commands[brew] )); then
  local bsz=$(sc_size_of $(brew --cache 2>/dev/null))
  sc_run "brew cleanup -s --prune=all  ($(sc_human $bsz))" brew cleanup -s --prune=all
fi

# Language/toolchain build caches — all rebuild on next compile.
sc_rm "Go build cache"           ~/Library/Caches/go-build(N)
sc_rm "JetBrains caches"         ~/Library/Caches/JetBrains(N)
sc_rm "rattler (conda) cache"    ~/Library/Caches/rattler(N)
sc_rm "node-gyp cache"           ~/Library/Caches/node-gyp(N)
sc_rm "CocoaPods cache"          ~/Library/Caches/CocoaPods(N)
sc_rm "pip cache"                ~/Library/Caches/pip(N)
sc_rm "Yarn cache"               ~/Library/Caches/Yarn(N)
sc_rm "Spotify cache"            ~/Library/Caches/com.spotify.client(N)

(( $+commands[pnpm] )) && sc_run "pnpm store prune"      pnpm store prune
(( $+commands[npm]  )) && sc_run "npm cache clean"       npm cache clean --force
(( $+commands[uv]   )) && sc_run "uv cache prune"        uv cache prune

# =================================================================== TIER 2 ==
if (( tier >= 2 )); then
  sc_hdr "Tier 2 — costs a re-download or rebuild"
  sc_rm "Gradle caches"            ~/.gradle/caches(N)
  sc_rm "Playwright browsers"      ~/Library/Caches/ms-playwright(N) ~/Library/Caches/ms-playwright-go(N)
  sc_rm "Android build cache"      ~/.android/cache(N)
  (( $+commands[xcrun] )) && sc_run "delete unavailable simulators" xcrun simctl delete unavailable
  sc_info "Docker is handled separately: ./bin/docker-reclaim.zsh"
fi

# =================================================================== TIER 3 ==
if (( tier >= 3 )); then
  sc_hdr "Tier 3 — DATA. Reported only, never auto-deleted."
  local -a review
  review=(
    ~/.ollama ~/models
    ~/Library/Containers/com.inferencer
    ~/Library/Application\ Support/com.apple.container
    ~/Downloads ~/.cache ~/.npm ~/.pub-cache ~/.konan ~/.rustup ~/.sdkman ~/fvm
  )
  {
    for p in $review; do
      local sz=$(sc_size_of $p)
      (( sz > 200000000 )) && printf '%d\t%s\t%s\n' $sz "$(sc_human $sz)" "${p/#$HOME/~}"
    done
  } | sort -rn -k1 | awk -F'\t' '{printf "      %10s  %s\n", $2, $3}'
  sc_info "Decide these by hand. Local LLM models and Downloads are not cache."
fi

# ================================================================ SNAPSHOTS ==
# THE STEP EVERYONE FORGETS. Files deleted above are still referenced by any
# local Time Machine snapshot taken before now — until thinned, free space
# does not move and it looks like the cleanup did nothing.
if (( SC_APPLY )) && [[ -z ${SC_NO_THIN:-} ]]; then
  sc_hdr "Releasing snapshot-pinned blocks"
  sc_thin_snapshots
fi

sc_tm_restore

# =================================================================== RESULT ==
local after=$(sc_free_bytes)
sc_hdr "Result"
if (( SC_APPLY )); then
  print -r -- "      before   $(sc_human $before)"
  print -r -- "      after    $(sc_human $after)"
  print -r -- "      ${SC_BLD}reclaimed $(sc_human $(( after - before )))${SC_RST}   now $(sc_pct_free)% free"
  sc_log "reclaim tier=$tier freed=$(( after - before )) free_pct=$(sc_pct_free)"
else
  print -r -- "      dry run — nothing removed. Re-run with ${SC_BLD}--apply${SC_RST}."
fi
print
