#!/usr/bin/env zsh
# <xbar.title>sparkling-clean</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>sparkling-clean</xbar.author>
# <xbar.desc>Disk, swap-headroom and Time Machine health in the menu bar.</xbar.desc>
# <xbar.dependencies>zsh</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
#
# SwiftBar / xbar plugin. Install:
#   brew install --cask swiftbar
#   ln -s "$PWD/extra/swiftbar/sparkling-clean.10m.sh" ~/Library/Application\ Support/SwiftBar/
#
# Reads disk-guard --json (~0.4s). It deliberately does NOT run the full report,
# which walks 100k-entry trees with find(1) and takes tens of seconds — far too
# slow for something the menu bar re-runs every ten minutes.
#
# Nothing here needs sudo or Full Disk Access: every check behind it is
# read-only and unprivileged by design.

emulate -L zsh
setopt no_err_return

# Resolve the toolkit whether this is symlinked from a checkout or installed by
# Homebrew. SwiftBar runs plugins with a minimal PATH, so brew --prefix is not
# assumed to be on it.
local SC=""
for candidate in \
  "${0:A:h:h:h}/bin/disk-guard.zsh" \
  "/opt/homebrew/opt/sparkling-clean/libexec/disk-guard.zsh" \
  "/usr/local/opt/sparkling-clean/libexec/disk-guard.zsh"
do
  [[ -x $candidate || -r $candidate ]] && { SC=$candidate; break }
done

if [[ -z $SC ]]; then
  print -r -- "💾 ?"
  print -r -- "---"
  print -r -- "sparkling-clean not found | color=red"
  print -r -- "Expected beside this plugin or under brew's opt prefix."
  exit 0
fi

local json
json=$(zsh "$SC" --json 2>/dev/null)
if [[ -z $json ]]; then
  print -r -- "💾 ?"
  print -r -- "---"
  print -r -- "guard produced no output | color=red"
  exit 0
fi

# Minimal field extraction — no jq, to keep the zero-dependency promise.
jget() { print -r -- "$json" | sed -E "s/.*\"$1\":\"([^\"]*)\".*/\1/" }

local level=$(jget level)
local subject=$(jget subject)
local headline=$(jget headline)

case $level in
  (CRIT) print -r -- "💾 ${subject}: ${headline} | color=red"    ;;
  (WARN) print -r -- "💾 ${subject}: ${headline} | color=orange" ;;
  (*)    print -r -- "💾"                                        ;;   # quiet when healthy
esac

print -r -- "---"

# One line per check, colour-coded, worst first is not needed — order is stable
# and matches the report.
print -r -- "$json" \
  | grep -oE '\{"level":"[A-Z]+","name":"[^"]+","headline":"[^"]+"\}' \
  | while read -r row; do
      local l=$(print -r -- "$row" | sed -E 's/.*"level":"([^"]*)".*/\1/')
      local n=$(print -r -- "$row" | sed -E 's/.*"name":"([^"]*)".*/\1/')
      local h=$(print -r -- "$row" | sed -E 's/.*"headline":"([^"]*)".*/\1/')
      case $l in
        (CRIT) print -r -- "✗ ${n}: ${h} | color=red"    ;;
        (WARN) print -r -- "△ ${n}: ${h} | color=orange" ;;
        (*)    print -r -- "✓ ${n}: ${h}"                ;;
      esac
    done

# Notes are context, never alarming — dimmed, matching the CHECK/NOTE split.
# Strip the "notes":[ ... ] wrapper FIRST; grepping quoted strings across the
# whole blob also matches the key "notes" itself.
local notes_blob=$(print -r -- "$json" | sed -E 's/.*"notes":\[//; s/\].*//')
if [[ -n $notes_blob ]]; then
  print -r -- "$notes_blob" | tr ',' '\n' | sed -E 's/^"//; s/"$//' \
    | while read -r note; do
        [[ -n $note ]] && print -r -- "${note} | size=11 color=gray"
      done
fi

print -r -- "---"
# terminal=true opens Terminal and runs the command there. Two entries, because
# the two reports have very different costs and a menu click should not spring a
# surprise password prompt:
#   --brief  ~1.5s, no sudo   — space, snapshots, Time Machine, exclusions
#   full     ~40s, sudo       — adds SMART, which needs `sudo smartctl`
local cli=${SC:h}/sparkling-clean
if [[ -x $cli ]]; then
  print -r -- "Quick summary… | bash=${cli} param1=report param2=--brief terminal=true"
  print -r -- "Full report (~40s, asks for sudo)… | bash=${cli} param1=report terminal=true"
fi
print -r -- "Refresh | refresh=true"
