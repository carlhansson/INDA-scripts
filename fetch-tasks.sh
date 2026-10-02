#!/usr/bin/env bash
#   ./fetch-tasks.sh task-1               clone (or update) into ./<student-id>/task-1
#   ./fetch-tasks.sh task-1 task-2        several tasks in one run
#   ./fetch-tasks.sh -r task-1 task-2     delete existing clones and start over
#   ./fetch-tasks.sh -s carlhans,meya     task-1 only fetch the listed students
#
set -uo pipefail

HOST="gits-15.sys.kth.se"
ORG="inda-26"
PROTO="ssh"
STUDENTS_FILE="students.txt"

usage() {
  cat <<EOF
Usage: ${0##*/} [-r] [-s student-id[,student-id ...]] <task-name> [task-name ...]

Clones each <task-name> for every student id listed in ./$STUDENTS_FILE
(one id per row), or only the ids given with -s, into ./<student-id>/<task-name>/.

Existing clones are updated with a fast-forward-only pull, so local
changes are never discarded. If you want to discard local changes use
the -r option.

Options:
  -r    Re-clone from scratch: delete existing clones first
  -s    Only fetch these students instead of everyone in $STUDENTS_FILE;
        separate ids with commas or spaces, or repeat -s
  -h    Show this help

Host/org/naming are set in the configuration block at the top of the script.
EOF
}

die() {
  echo "Error: $1" >&2
  exit 1
}

RECLONE=0
ONLY=()
while getopts ':rs:h' opt; do
  case "$opt" in
    r) RECLONE=1 ;;
    s)
      read -ra ids <<<"${OPTARG//,/ }"
      ONLY+=("${ids[@]}")
      ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "Option -$OPTARG needs an argument." >&2
      usage >&2
      exit 2
      ;;
    *)
      echo "Unknown option: -$OPTARG" >&2
      usage >&2
      exit 2
      ;;
  esac
done
shift $((OPTIND - 1))
TASKS=("$@")

(($#)) || {
  usage >&2
  exit 2
}
command -v git >/dev/null || die "git not found."

if [[ "$PROTO" == "ssh" ]]; then
  BASE="git@$HOST:$ORG"
else
  BASE="https://$HOST/$ORG"
fi

if ((${#ONLY[@]})); then
  mapfile -t STUDENTS < <(printf '%s\n' "${ONLY[@]}" | awk 'NF && !seen[$1]++ { print $1 }')
else
  [[ -r "$STUDENTS_FILE" ]] || die "no readable $STUDENTS_FILE in $PWD."
  mapfile -t STUDENTS < <(sed 's/#.*//' "$STUDENTS_FILE" | tr -d '\r' | awk 'NF && !seen[$1]++ { print $1 }')
fi
((${#STUDENTS[@]})) || die "no student ids in $STUDENTS_FILE."

JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
TOTAL=$((${#STUDENTS[@]} * ${#TASKS[@]}))

if [[ -t 1 ]]; then
  R=$(tput sgr0)
  RED=$(tput setaf 1) GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3)
else
  R='' RED='' GREEN='' YELLOW=''
fi

say() {
  printf '%-20s %-12s %s\n' "$@"
}

fail() {
  say "$1" "$2" "${RED}FAILED${R}"
  sed 's/^/    /' <<<"$3"
  return 1
}

head_desc() {
  git -C "$1" log -1 --format='%h %cs' 2>/dev/null || echo "(empty repo — nothing pushed)"
}

fetch_one() {
  local student="$1" task="$2" dir="$1/$2" err before

  ((RECLONE)) && rm -rf "$dir"

  if [[ ! -d "$dir/.git" ]]; then
    mkdir -p "$student"
    err=$(git clone --quiet "$BASE/$student-$task.git" "$dir" 2>&1) || {
      fail "$student" "$task" "$err"
      return 1
    }
    say "$student" "$task" "${GREEN}cloned${R}     $(head_desc "$dir")"
    return 0
  fi

  err=$(git -C "$dir" fetch --quiet --prune origin 2>&1) || {
    fail "$student" "$task" "$err"
    return 1
  }

  before=$(git -C "$dir" rev-parse -q --verify HEAD)
  if ! git -C "$dir" rev-parse -q --verify '@{u}' >/dev/null 2>&1 ||
    git -C "$dir" merge --ff-only --quiet '@{u}' 2>/dev/null; then
    if [[ "$(git -C "$dir" rev-parse -q --verify HEAD)" == "$before" ]]; then
      say "$student" "$task" "${YELLOW}no changes${R} $(head_desc "$dir")"
    else
      say "$student" "$task" "${GREEN}updated${R}    $(head_desc "$dir")"
    fi
  else
    say "$student" "$task" "${RED}diverged (left alone)${R}"
  fi
}

export -f fetch_one say fail head_desc
export BASE RECLONE R RED GREEN YELLOW GIT_TERMINAL_PROMPT=0

echo "${TASKS[*]}: ${#STUDENTS[@]} students, $TOTAL repos, $JOBS parallel jobs"
((RECLONE)) && echo "re-cloning from scratch"
echo

status=0
for task in "${TASKS[@]}"; do
  printf '%s\n' "${STUDENTS[@]}" |
    xargs -P "$JOBS" -I{} bash -c 'fetch_one "$@"' _ {} "$task" || status=1
done

echo
if ((status == 0)); then
  echo "All $TOTAL repos fetched."
else
  echo "Finished with failures — see the lines above."
fi
