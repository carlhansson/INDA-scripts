#!/usr/bin/env bash
#   ./fetch-tasks.sh task-1               clone (or update) into ./<student-id>/task-1
#   ./fetch-tasks.sh task-1 task-2        several tasks in one run
#   ./fetch-tasks.sh -r task-1 task-2     delete existing clones and start over
#
set -uo pipefail

HOST="gits-15.sys.kth.se" # GitHub Enterprise hostname
ORG="inda-26"             # organization owning the repos
PROTO="ssh"               # "ssh" or "https"

repo_path() {
    local student="$1" task="$2"
    echo "$ORG/$student-$task"
}

STUDENTS_FILE="students.txt"
RECLONE=0

usage() {
    cat <<EOF
Usage: ${0##*/} [-r] <task-name> [task-name ...]

Clones each <task-name> for every student id listed in ./$STUDENTS_FILE
(one id per row) into ./<student-id>/<task-name>/.

Existing clones are updated with a fast-forward-only pull, so local
changes are never discarded. If you want to discard local changes use
the -r option.

Options:
  -r    Re-clone from scratch: delete existing clones first
  -h    Show this help

Host/org/naming are set in the configuration block at the top of the script.
EOF
}

while getopts ':rh' opt; do
    case "$opt" in
        r) RECLONE=1 ;;
        h)
            usage
            exit 0
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
((${#TASKS[@]})) || {
    echo "Error: at least one task name is required." >&2
    usage >&2
    exit 2
}
[[ -r "$STUDENTS_FILE" ]] || {
    echo "Error: no readable $STUDENTS_FILE in $PWD." >&2
    exit 1
}
command -v git >/dev/null || {
    echo "Error: git not found." >&2
    exit 2
}

head_desc() {
    git -C "$1" log -1 --format='%h %cs' 2>/dev/null || echo "(empty repo — nothing pushed)"
}

report_err() {
    printf '%-20s %-12s FAILED (%s)\n    %s\n' "$1" "$2" "$3" "${4//$'\n'/$'\n'    }"
}

fetch_one() {
    local student="$1" task="$2" full url dir err
    full="$(repo_path "$student" "$task")"
    dir="$student/$task"

    if [[ "$PROTO" == "ssh" ]]; then
        url="git@$HOST:$full.git"
    else
        url="https://$HOST/$full.git"
    fi

    ((RECLONE)) && rm -rf "$dir"

    if [[ -d "$dir/.git" ]]; then
        if ! err=$(git -C "$dir" fetch --quiet --prune origin 2>&1); then
            report_err "$student" "$task" "$full" "$err"
            return 1
        fi
        if git -C "$dir" symbolic-ref -q HEAD >/dev/null \
            && git -C "$dir" rev-parse -q --verify '@{u}' >/dev/null 2>&1 \
            && ! git -C "$dir" merge --ff-only --quiet '@{u}' 2>/dev/null; then
            printf '%-20s %-12s diverged (left alone)\n' "$student" "$task"
            return 0
        fi
        printf '%-20s %-12s updated  %s\n' "$student" "$task" "$(head_desc "$dir")"
    else
        mkdir -p "$student"
        if ! err=$(git clone --quiet "$url" "$dir" 2>&1); then
            report_err "$student" "$task" "$full" "$err"
            return 1
        fi
        printf '%-20s %-12s cloned   %s\n' "$student" "$task" "$(head_desc "$dir")"
    fi
}

export -f fetch_one repo_path report_err head_desc
export HOST ORG PROTO RECLONE
export GIT_TERMINAL_PROMPT=0

mapfile -t STUDENTS < <(
    sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        "$STUDENTS_FILE" | grep -v '^$' | awk '!seen[$0]++'
)
((${#STUDENTS[@]})) || {
    echo "Error: no student ids in $STUDENTS_FILE." >&2
    exit 1
}

JOBS=$({ nproc || sysctl -n hw.ncpu; } 2>/dev/null || echo 4)
TOTAL=$((${#STUDENTS[@]} * ${#TASKS[@]}))

echo "${TASKS[*]}: ${#STUDENTS[@]} students, $TOTAL repos, $JOBS parallel jobs"
((RECLONE)) && echo "re-cloning from scratch"
echo

for task in "${TASKS[@]}"; do
    for student in "${STUDENTS[@]}"; do
        printf '%s\0%s\0' "$student" "$task"
    done
done | xargs -0 -P "$JOBS" -n 2 bash -c 'fetch_one "$@"' _
status=$?

echo
if ((status == 0)); then
    echo "All $TOTAL repos fetched."
else
    echo "Finished with failures — see the lines above."
fi
