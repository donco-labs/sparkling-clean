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
  "/opt/homebrew/opt/sparkling-clean/libexec/bin/disk-guard.zsh" \
  "/usr/local/opt/sparkling-clean/libexec/bin/disk-guard.zsh"
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
local cli=${SC:h}/sparkling-clean
if [[ -z $json ]]; then
  print -r -- "💾 ?"
  print -r -- "---"
  print -r -- "guard produced no output | color=red"
  exit 0
fi

# Minimal field extraction — no jq, to keep the zero-dependency promise.
# Restricted to the object prefix BEFORE "checks": the keys level/headline also
# appear inside every check, and sed's greedy .* would otherwise return the LAST
# match — pairing the worst check's subject with a different check's headline.
local head=${json%%,\"checks\":*}
jget() { print -r -- "$head" | sed -E "s/.*\"$1\":\"([^\"]*)\".*/\1/" }

local level=$(jget level)
local subject=$(jget subject)
local headline=$(jget headline)

# SF Symbols render as template images: monochrome, and they follow the menu bar
# appearance the way every native item does. An emoji cannot — it is always full
# colour, and 💾 is a save icon from 1998 besides.
#
# Text costs horizontal space that the menu bar does not have, so only a CRIT
# earns any, and then only the subject. A WARN changes the glyph and nothing
# else: enough to notice, not enough to crowd out anything.
# Severity is weight, not a different symbol. The glyph stays a drive so the item
# is recognisable at a glance in a crowded menu bar, and a warning simply fills
# it in. Only a genuine emergency changes the symbol — a caution triangle for
# "21 snapshots accumulated" reads the same as one for "no backup in 61 days",
# and those are not comparable problems.
case $level in
  (CRIT) print -r -- "${subject} | sfimage=exclamationmark.triangle.fill" ;;
  (WARN) print -r -- "| sfimage=internaldrive.fill"                       ;;
  (*)    print -r -- "| sfimage=internaldrive"                            ;;
esac

print -r -- "---"
print -r -- "sparkling-clean · disk and backup health | size=11 color=gray href=https://github.com/donco-labs/sparkling-clean"
print -r -- "---"

# One line per check, colour-coded, worst first is not needed — order is stable
# and matches the report.
print -r -- "$json" \
  | grep -oE '\{"level":"[A-Z]+","name":"[^"]+","headline":"[^"]+","detail":"[^"]*"\}' \
  | while read -r row; do
      local l=$(print -r -- "$row" | sed -E 's/.*"level":"([^"]*)".*/\1/')
      local n=$(print -r -- "$row" | sed -E 's/.*"name":"([^"]*)".*/\1/')
      local h=$(print -r -- "$row" | sed -E 's/.*"headline":"([^"]*)".*/\1/')
      local d=$(print -r -- "$row" | sed -E 's/.*"detail":"([^"]*)".*/\1/')
      case $l in
        (CRIT) print -r -- "✗ ${n}: ${h} | color=red"    ;;
        (WARN) print -r -- "△ ${n}: ${h} | color=orange" ;;
        (*)    print -r -- "✓ ${n}: ${h}"                ;;
      esac
      # Explanation goes here, where there is room for it — never in the title.
      [[ $l != OK && -n $d && $d != "$h" ]] && print -r -- "   ${d} | size=11 color=gray"
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

# Naming a problem without saying what to do about it is half a monitor. The
# snapshot check is the one people most often cannot act on unaided, so when it
# fires, offer the fix rather than describing it.
if print -r -- "$json" | grep -q '"level":"WARN","name":"Snapshots"'; then
  [[ -x $cli ]] && print -r -- "Thin snapshots to reclaim that space… | bash=${cli} param1=thin terminal=true"
fi

# terminal=true opens Terminal and runs the command there. Two entries, because
# the two reports have very different costs and a menu click should not spring a
# surprise password prompt:
#   --brief  ~1.5s, no sudo   — space, snapshots, Time Machine, exclusions
#   full     ~40s, sudo       — adds SMART, which needs `sudo smartctl`
if [[ -x $cli ]]; then
  print -r -- "Quick summary… | bash=${cli} param1=report param2=--brief terminal=true"
  print -r -- "Full report (~40s, asks for sudo)… | bash=${cli} param1=report terminal=true"
fi
print -r -- "Refresh | refresh=true"
print -r -- "---"
print -r -- "What these checks mean… | href=https://github.com/donco-labs/sparkling-clean/blob/main/docs/GUIDE.md"
