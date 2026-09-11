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

# Row colour rides in the text as an ANSI escape, not in the `color=` parameter,
# because on macOS 26 SwiftBar (2.1.2b3) renders every row as an attributed
# title and wraps a `color=`-styled one in a tracking subclass:
#
#     item.attributedTitle = if params.color != nil, !params.ansi {
#         MenuTrackingAttributedTitle(titleWithImage)
#
# That subclass forces NSColor.selectedMenuItemTextColor over the row while the
# pointer is on it. Un-highlighting flips the flag back and calls itemChanged(),
# which on macOS 26 does not make AppKit re-read the title -- so the row keeps
# the highlight colour until the whole menu is rebuilt. An orange WARN went dark
# on rollover and stayed dark until the menu was closed and reopened.
#
# An ANSI-coloured row is exempt from that wrapper. `color=` stays on every row
# anyway: SwiftBar gives a row a target only when it has an action OR a colour,
# and a row with no target is auto-disabled -- dimmed, and refusing to highlight.
# Verified in SwiftBar on 2026-09-11: ANSI rows survive rollover, param-coloured
# rows do not, and an ANSI row without `color=` renders washed out.
#
# Indices rather than names, because SwiftBar's 256-colour table is its own
# arithmetic: these three resolve to rgb(255,135,0), pure red, and #808080.
local SC_TINT_WARN=$'\e[38;5;208m'
local SC_TINT_CRIT=$'\e[38;5;196m'
local SC_TINT_DIM=$'\e[38;5;244m'

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
  print -r -- "${SC_TINT_CRIT}sparkling-clean not found | color=red ansi=true"
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
  print -r -- "${SC_TINT_CRIT}guard produced no output | color=red ansi=true"
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
print -r -- "${SC_TINT_DIM}sparkling-clean · disk and backup health | size=11 color=gray ansi=true href=https://github.com/donco-labs/sparkling-clean"
print -r -- "---"

# SwiftBar sizes the dropdown to its longest row, and a note is a full sentence.
# Wrap rather than truncate: losing the tail of a sentence is worse than using
# two rows for it.
#
# Check details used to come through here too, until they moved into tooltips.
# Notes have no row of their own to hang a tooltip on -- they ARE the row -- so
# this is what they still use.
#
# A literal "|" would be read as the start of SwiftBar's parameter list and
# silently eat the rest of the row, so it is replaced before emitting.
sc_menu_wrapped() {   # $1 = text · $2 = leading indent · $3 = params · $4 = tint
  local text=${1//|/\u2502} line
  print -r -- "$text" | fold -s -w 64 | while IFS= read -r line; do
    [[ -n ${line// } ]] || continue
    # fold -s leaves the break space on the end of each line; EXTENDED_GLOB is
    # not set here, so trim it the plain way rather than with "${line%% ##}".
    while [[ $line == *' ' ]]; do line=${line% }; done
    print -r -- "${2}${4}${line} | ${3}"
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
      # Every row gets a colour, including the healthy ones, and that is not
      # only about colour. SwiftBar hands an item a target/action when it has
      # an action OR a colour:
      #
      #     if params.hasAction || params.color != nil { item.target = self ... }
      #
      # A tooltip does not qualify. So an uncoloured row got no target, AppKit
      # auto-disabled it, and it rendered grey and refused to highlight -- the
      # system's universal "this does nothing". That was exactly backwards for
      # the OK rows: since the visible detail lines went away, hovering is the
      # ONLY way to read them, and they were the ones styled as inert.
      #
      # A dim grey keeps them recessive against the orange and red, so the
      # severity hierarchy survives; what changes is that they now highlight
      # under the pointer, which is the affordance that says "there is something
      # here". One mid grey rather than a light,dark pair: the colour is an ANSI
      # index now and those are literal RGB, so #808080 is the value that stays
      # legible against a light menu and a dark one both.
      local params="" icon="✓" tint=""
      case $l in
        (CRIT) icon="✗"; tint=$SC_TINT_CRIT; params="color=red ansi=true"    ;;
        (WARN) icon="△"; tint=$SC_TINT_WARN; params="color=orange ansi=true" ;;
        (*)              tint=$SC_TINT_DIM;  params="color=gray ansi=true"   ;;
      esac
      [[ -n $tip && $tip != "$h" ]] && params="${params:+$params }tooltip=\"${tip}\""
      print -r -- "${tint}${icon} ${n}: ${h}${params:+ | $params}"

      # The explanation lives in the tooltip and nowhere else. Printing it in
      # the open as well put the same sentence on screen twice -- once under
      # the row, once floating beside it -- and cost up to five rows to do it.
      #
      # It is not hiding anything. A condition that needs acting on is PUSHED:
      # the guard's notification body is built from these same detail strings,
      # so a problem announces itself rather than waiting to be hovered. The
      # dropdown is the passive surface, and the one condition deliberately not
      # pushed -- "destination away" -- is also the one whose headline already
      # says the whole thing.
      #
      # The exception is an ACTION, which is not an explanation: the thin offer
      # for snapshots below still gets a row of its own, because a fix nobody
      # can find is not a fix.
    done

# A point-in-time check tells you where you are; the trend tells you where you
# are going, which is the view that would have caught the original incident
# months earlier.
local hist=$(sc_free_history 24 2>/dev/null)
if [[ -n $hist ]]; then
  local spark=$(print -r -- "$hist" | sc_sparkline)
  local delta=$(print -r -- "$hist" | sc_free_delta)
  [[ -n $spark ]] && print -r -- "   ${SC_TINT_DIM}${spark}  ${delta} | font=Menlo size=12 color=gray ansi=true"
fi

# Notes are context, never alarming — dimmed, matching the CHECK/NOTE split.
# Strip the "notes":[ ... ] wrapper FIRST; grepping quoted strings across the
# whole blob also matches the key "notes" itself.
local notes_blob=$(print -r -- "$json" | sed -E 's/.*"notes":\[//; s/\].*//')
if [[ -n $notes_blob ]]; then
  print -r -- "$notes_blob" | tr ',' '\n' | sed -E 's/^"//; s/"$//' \
    | while read -r note; do
        [[ -n $note ]] && sc_menu_wrapped "$note" "" "size=11 color=gray ansi=true" "$SC_TINT_DIM"
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
  print -r -- "--${SC_TINT_DIM}$(sc_human $tot) across ${cnt} watched directories | color=gray ansi=true"
  print -r -- "--${SC_TINT_DIM}Caches and images regrow; watch the shape, not the total. | color=gray ansi=true"
fi
print -r -- "---"
print -r -- "About sparkling-clean"
print -r -- "--${SC_TINT_DIM}Version $(sc_version "$SC") | color=gray ansi=true"
print -r -- "--${SC_TINT_DIM}Warn below ${SC_WARN_PCT}% free · critical below ${SC_CRIT_PCT}% | color=gray ansi=true"
print -r -- "--${SC_TINT_DIM}Backup stale after ${SC_TM_WARN_D}d · critical after ${SC_TM_CRIT_D}d | color=gray ansi=true"
print -r -- "--${SC_TINT_DIM}Failing attempts critical after ${SC_TM_FAIL_CRIT_H}h | color=gray ansi=true"
print -r -- "-----"
print -r -- "--What these checks mean… | href=https://github.com/donco-labs/sparkling-clean/blob/main/docs/GUIDE.md"
print -r -- "--Repository… | href=https://github.com/donco-labs/sparkling-clean"
print -r -- "--Report an issue… | href=https://github.com/donco-labs/sparkling-clean/issues/new"
print -r -- "-----"
print -r -- "--${SC_TINT_DIM}Checks run every 2h in the background | color=gray ansi=true"
print -r -- "--${SC_TINT_DIM}Nothing here changes your Mac without asking | color=gray ansi=true"
