#!/usr/bin/env zsh
# docker-reclaim.zsh — reclaim Docker Desktop space safely. DRY-RUN BY DEFAULT.
#
#   ./bin/docker-reclaim.zsh            report what is reclaimable
#   ./bin/docker-reclaim.zsh --apply    prune build cache + untagged images
#   ./bin/docker-reclaim.zsh --apply --compact   …then quit Docker so it compacts
#
# SAFETY: this script NEVER prunes volumes. See the note in the Volumes section.

emulate -L zsh
setopt no_err_return
source ${0:A:h}/lib/common.zsh
sc_require_macos

local compact=0
while (( $# )); do
  case $1 in
    --apply)    SC_APPLY=1 ;;
    --compact)  compact=1 ;;
    -h|--help)  sed -n '2,12p' ${0:A}; exit 0 ;;
    *) print -ru2 -- "unknown flag: $1"; exit 2 ;;
  esac
  shift
done

local RAW=~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw

print -r -- "${SC_BLD}docker-reclaim${SC_RST}  mode=$( (( SC_APPLY )) && print APPLY || print DRY-RUN )"

# Docker.raw is SPARSE. `ls -lh` reports the ceiling (typically 460G); only `du`
# reports what is actually on disk.
[[ -e $RAW ]] && print -r -- "Docker.raw on disk: $(sc_size_h $RAW)   (ls -lh would show the sparse ceiling)"

if ! docker info >/dev/null 2>&1; then
  sc_warn "Docker daemon not responding."
  sc_info "Start it, wait ~60s, re-run:   open -a Docker"
  sc_info "Note: transient 500s from the API usually mean Resource Saver is"
  sc_info "stopping the VM, not that the daemon is wedged. Check again in a minute."
  exit 1
fi

sc_hdr "Current usage"
docker system df 2>/dev/null | sed 's/^/      /'

# ============================================================ BUILD CACHE ====
# Safest possible reclaim: pure build artifacts, rebuilt on demand, never data.
sc_hdr "Build cache — safe"
local bc=$(docker system df --format '{{.Type}} {{.Size}}' 2>/dev/null | awk '/Build/{print $2}')
sc_run "docker builder prune -a  (${bc:-?})" docker builder prune -a -f

# ================================================================= IMAGES ====
# Untagged (repo:<none>) images are superseded layers left behind when a tag was
# re-pulled. They are never referenced by name and are the usual bulk offender.
sc_hdr "Untagged images — safe"
local -a untagged
untagged=(${(f)"$(docker image ls --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null | grep ':<none>$' | cut -d' ' -f1)"})
if (( ${#untagged} )); then
  docker image ls --format '{{.Size}}\t{{.Repository}}:{{.Tag}}\t{{.CreatedSince}}' 2>/dev/null \
    | grep ':<none>' | sed 's/^/        /'
  sc_run "remove ${#untagged} untagged image(s)" docker rmi ${untagged}
else
  sc_ok "none"
fi

sc_hdr "Dangling images — safe"
local -a dangling
dangling=(${(f)"$(docker image ls -qf dangling=true 2>/dev/null)"})
if (( ${#dangling} )); then
  sc_run "remove ${#dangling} dangling image(s)" docker rmi ${dangling}
else
  sc_ok "none"
fi

# ================================================================ VOLUMES ====
# DO NOT PRUNE. A named volume shows as "dangling" the moment its container is
# removed — but it still holds the data. `docker volume prune` cannot tell
# ambit_postgres-data from scratch space, and it is usually a small win anyway
# (single-digit % of Docker's footprint). Report, never delete.
sc_hdr "Volumes — REPORTED ONLY, never pruned"
local -a dvols
dvols=(${(f)"$(docker volume ls -qf dangling=true 2>/dev/null)"})
if (( ${#dvols} )); then
  sc_warn "${#dvols} unreferenced volume(s). Named ones are almost certainly real data:"
  for v in ${dvols}; do
    # Heuristic: 64-hex names are anonymous scratch; anything else was named by a human.
    if [[ $v == [0-9a-f](#c64) ]]; then print -r -- "        ${SC_DIM}$v  (anonymous)${SC_RST}"
    else                                print -r -- "        ${SC_YEL}$v  ← NAMED — likely real data${SC_RST}"
    fi
  done
  sc_info "Remove individually only when certain:  docker volume rm <name>"
else
  sc_ok "no unreferenced volumes"
fi

sc_hdr "Stopped containers"
docker ps -a --filter status=exited --format '        {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | head -15
sc_info "Removing a container un-protects its image AND its named volumes."
sc_info "Remove by name when you are done with it:  docker rm <name>"

# =============================================================== COMPACTION ==
# Pruning frees space INSIDE the VM's filesystem. Docker.raw only shrinks when
# Docker Desktop compacts it, which it does on a clean shutdown.
sc_hdr "Compaction"
if (( compact && SC_APPLY )); then
  sc_info "quitting Docker Desktop so it compacts Docker.raw…"
  osascript -e 'quit app "Docker"' 2>/dev/null
  local i
  for i in {1..30}; do
    pgrep -f 'Docker.app/Contents/MacOS/com.docker' >/dev/null 2>&1 || break
    sleep 2
  done
  sleep 5
  print -r -- "      Docker.raw now: $(sc_size_h $RAW)"
else
  sc_info "Pruning frees space inside the VM; Docker.raw shrinks only on a clean"
  sc_info "Docker Desktop shutdown. Re-run with --apply --compact, or quit Docker"
  sc_info "from the menu bar. If it still will not shrink, use Settings →"
  sc_info "Resources → Disk image size (WARNING: recreates the image and destroys"
  sc_info "every container, image and volume inside it)."
fi
print
