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

source ${SC:h}/lib/common.zsh 2>/dev/null

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

# SwiftBar sizes the dropdown to its longest row, and check details are full
# sentences: one measured 235 characters and stretched the menu across most of
# the screen. Wrap rather than truncate -- the detail is the part that says what
# to do about the problem, so losing its tail is worse than using three rows.
#
# A literal "|" would be read as the start of SwiftBar's parameter list and
# silently eat the rest of the row, so it is replaced before emitting.
sc_menu_wrapped() {   # $1 = text · $2 = leading indent · $3 = params
  local text=${1//|/\u2502} line
  print -r -- "$text" | fold -s -w 64 | while IFS= read -r line; do
    [[ -n ${line// } ]] || continue
    # fold -s leaves the break space on the end of each line; EXTENDED_GLOB is
    # not set here, so trim it the plain way rather than with "${line%% ##}".
    while [[ $line == *' ' ]]; do line=${line% }; done
    print -r -- "${2}${line} | ${3}"
  done
}

# One line per check, colour-coded, worst first is not needed — order is stable
# and matches the report.
print -r -- "$json" \
  | grep -oE '\{"level":"[A-Z]+","name":"[^"]+","headline":"[^"]+","detail":"[^"]*"\}' \
  | while read -r row; do
      local l=$(print -r -- "$row" | sed -E 's/.*"level":"([^"]*)".*/\1/')
      local n=$(print -r -- "$row" | sed -E 's/.*"name":"([^"]*)".*/\1/')
      local h=$(print -r -- "$row" | sed -E 's/.*"headline":"([^"]*)".*/\1/')
      local d=$(print -r -- "$row" | sed -E 's/.*"detail":"([^"]*)".*/\1/')
      # The full sentence rides along as a tooltip. It costs no row and no
      # width, and it is the only way an OK row's detail is reachable at all --
      # visible detail rows are printed for problems only, so on a healthy
      # machine every detail string was going into the JSON and reaching no
      # one. Hovering now answers "why is this OK" as well as "why is this not".
      #
      # A literal " would end the quoted parameter early and a literal | would
      # start a second parameter list, so both are neutralised first.
      local tip=${d//\"/}
      tip=${tip//|/\u2502}

      # Built up rather than interpolated per branch, so a row with nothing to
      # add prints no trailing "|" at all. A bare pipe is a parameter list with
      # no parameters in it, which is not something to hand a parser on purpose.
      local params="" icon="✓"
      case $l in
        (CRIT) icon="✗"; params="color=red"    ;;
        (WARN) icon="△"; params="color=orange" ;;
      esac
      [[ -n $tip && $tip != "$h" ]] && params="${params:+$params }tooltip=\"${tip}\""
      print -r -- "${icon} ${n}: ${h}${params:+ | $params}"
      # Problems also get it in the open, where it cannot be missed.
      [[ $l != OK && -n $d && $d != "$h" ]] && sc_menu_wrapped "$d" "   " "size=11 color=gray"
    done

# A point-in-time check tells you where you are; the trend tells you where you
# are going, which is the view that would have caught the original incident
# months earlier.
local hist=$(sc_free_history 24 2>/dev/null)
if [[ -n $hist ]]; then
  local spark=$(print -r -- "$hist" | sc_sparkline)
  local delta=$(print -r -- "$hist" | sc_free_delta)
  [[ -n $spark ]] && print -r -- "   ${spark}  ${delta} | font=Menlo size=12 color=gray"
fi

# Notes are context, never alarming — dimmed, matching the CHECK/NOTE split.
# Strip the "notes":[ ... ] wrapper FIRST; grepping quoted strings across the
# whole blob also matches the key "notes" itself.
local notes_blob=$(print -r -- "$json" | sed -E 's/.*"notes":\[//; s/\].*//')
if [[ -n $notes_blob ]]; then
  print -r -- "$notes_blob" | tr ',' '\n' | sed -E 's/^"//; s/"$//' \
    | while read -r note; do
        [[ -n $note ]] && sc_menu_wrapped "$note" "" "size=11 color=gray"
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

# Where the space actually lives. Read from the cache rather than measured here
# — see sc_sizes_refresh for why a menu bar item must not walk 100k-entry trees
# every ten minutes. Numbers are up to half a day old, which is the right
# resolution for watching creep.
local sizes=$(sc_sizes_read 2>/dev/null)
if [[ -n $sizes ]]; then
  local age=$(sc_sizes_age_hours)
  local when="${age}h ago"; (( age < 1 )) && when="just now"
  print -r -- "---"
  print -r -- "Watchlist · measured ${when}"
  # No cap — this is a submenu and the whole point is seeing the shape of the
  # set. A floor instead, so trivial entries do not pad the list.
  : ${SC_WATCH_FLOOR:=104857600}          # 100 MB
  # Rows are deliberately inert. 0.4.0 gave them a
  #   | bash=/usr/bin/open param1="<path>" terminal=false
  # action and the submenu stopped opening at all; at 0.3.2, with these rows
  # bare, it opened. That is the whole of what is established.
  #
  # The mechanism is NOT established. Several of these paths contain spaces and
  # SwiftBar does not document how a param value containing spaces should be
  # written, so that is the suspicion — but it is a suspicion, not a finding.
  #
  # Do not add an action here again without opening the menu in SwiftBar and
  # looking. The emitted line looks perfectly correct printed to a terminal,
  # which is exactly how the broken version shipped.
  print -r -- "$sizes" | while IFS=$'\t' read -r b pth; do
    (( b >= SC_WATCH_FLOOR )) || continue
    printf -- '--%10s  %s\n' "$(sc_human $b)" "${pth/#$HOME/~}"
  done
  local tot=$(print -r -- "$sizes" | awk -F'\t' '{s+=$1} END{print s+0}')
  local cnt=$(print -r -- "$sizes" | grep -c .)
  print -r -- "-----"
  print -r -- "--$(sc_human $tot) across ${cnt} watched directories | color=gray"
  print -r -- "--Caches and images regrow; watch the shape, not the total. | color=gray"
fi
print -r -- "---"
print -r -- "About sparkling-clean"
print -r -- "--Version $(sc_version "$SC") | color=gray"
print -r -- "--Warn below ${SC_WARN_PCT}% free · critical below ${SC_CRIT_PCT}% | color=gray"
print -r -- "--Backup stale after ${SC_TM_WARN_D}d · critical after ${SC_TM_CRIT_D}d | color=gray"
print -r -- "--Failing attempts critical after ${SC_TM_FAIL_CRIT_H}h | color=gray"
print -r -- "-----"
print -r -- "--What these checks mean… | href=https://github.com/donco-labs/sparkling-clean/blob/main/docs/GUIDE.md"
print -r -- "--Repository… | href=https://github.com/donco-labs/sparkling-clean"
print -r -- "--Report an issue… | href=https://github.com/donco-labs/sparkling-clean/issues/new"
print -r -- "-----"
print -r -- "--Checks run every 2h in the background | color=gray"
print -r -- "--Nothing here changes your Mac without asking | color=gray"
