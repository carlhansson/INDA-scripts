#!/usr/bin/env bash
#   ./push-feedback.sh task-1          review and push every issue in feedback/task-1.md
#   ./push-feedback.sh -d task-1       dry run: show what would be pushed, push nothing
#   ./push-feedback.sh -y task-1       no confirmation prompts (use with care)
#
set -uo pipefail

HOST="gits-15.sys.kth.se"   # GitHub Enterprise hostname
ORG="inda-26"               # organization owning the repos
FEEDBACK_DIR="./0-feedback" # folder holding <task-name>.md feedback files

repo_path() {
  local student="$1" task="$2"
  echo "$ORG/$student-$task"
}

DRY_RUN=0
ASSUME_YES=0

usage() {
  cat <<EOF
Usage: ${0##*/} [-n] [-y] <task-name>

Reads $FEEDBACK_DIR/<task-name>.md, splits it into one issue per student and
creates each issue in repo https://$HOST/$ORG/<student-id>-<task-name>.

File format should be a header line which starts each student's feedback, everything up to
the next header line is that issue's body (in GitHub flavored markdown). For example:

    #meya#Pass

    Nice solution. A few notes:

    - [ ] note 1
    - [ ] note 2

    #carlhans#Komp

    Some things to fix:

    - [ ] note 1
    - [ ] note 2

The header is #<student-id>#<issue title>. Ordinary markdown headings (\`# Heading\`, \`## Sub\`) shouldn't be mistaken for it since we don't have any spaces around them.

Options:
  -d    Dry run: print each issue but never create anything
  -y    Assume yes: skip the per-issue confirmation
  -h    Show this help

Host/org/feedback folder are set in the configuration block at the top.
EOF
}

while getopts ':dyh' opt; do
  case "$opt" in
    d) DRY_RUN=1 ;;
    y) ASSUME_YES=1 ;;
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

(($# == 1)) || {
  echo "Error: exactly one task name is required." >&2
  usage >&2
  exit 2
}
TASK="$1"
FILE="$FEEDBACK_DIR/$TASK.md"

[[ -r "$FILE" ]] || {
  echo "Error: no readable $FILE." >&2
  exit 1
}
if ((! DRY_RUN)) && ! command -v gh >/dev/null; then
  echo "Error: gh not found. Install it (sudo pacman -S github-cli) and run:" >&2
  echo "    gh auth login --hostname $HOST" >&2
  exit 2
fi
if ((! DRY_RUN)) && ! gh auth status --hostname "$HOST" >/dev/null 2>&1; then
  echo "Error: gh is not authenticated for $HOST. Run:" >&2
  echo "    gh auth login --hostname $HOST" >&2
  exit 2
fi

if [[ -t 1 ]]; then
  B=$(tput bold) DIM=$(tput dim) R=$(tput sgr0)
  RED=$(tput setaf 1) GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3)
else
  B='' DIM='' R='' RED='' GREEN='' YELLOW=''
fi

trim_blank_lines() { # strip leading/trailing blank lines
  local s="$1"
  while [[ "$s" == $'\n'* ]]; do s="${s#$'\n'}"; done
  while [[ "$s" == *$'\n' ]]; do s="${s%$'\n'}"; done
  printf '%s' "$s"
}

# parse the feedback file into IDS / TITLES / BODIES

IDS=() TITLES=() BODIES=()
cur_id="" cur_title="" cur_body="" preamble=""

flush() {
  [[ -n "$cur_id" ]] || return 0
  IDS+=("$cur_id")
  TITLES+=("$cur_title")
  BODIES+=("$(trim_blank_lines "$cur_body")")
}

while IFS= read -r line; do
  if [[ "$line" =~ ^#([^#[:space:]]+)#[[:space:]]*(.*)$ ]]; then
    flush
    cur_id="${BASH_REMATCH[1]}"
    cur_title="${BASH_REMATCH[2]}"
    cur_title="${cur_title%"${cur_title##*[![:space:]]}"}" # rtrim
    cur_body=""
  elif [[ -n "$cur_id" ]]; then
    cur_body+="$line"$'\n'
  else
    preamble+="$line"
  fi
done < <(sed 's/\r$//' "$FILE")
flush

TOTAL=${#IDS[@]}
((TOTAL)) || {
  echo "Error: no '#<id>#<title>' header lines found in $FILE." >&2
  exit 1
}
[[ -z "${preamble//[[:space:]]/}" ]] ||
  echo "${YELLOW}Note: text before the first header line is ignored.${R}" >&2

echo "$FILE: $TOTAL issue(s) for task ${B}$TASK${R} on $HOST/$ORG"
((DRY_RUN)) && echo "${YELLOW}dry run — nothing will be created${R}"
echo

# review and push

pushed=0 skipped=0 failed=0 aborted=0

for ((i = 0; i < TOTAL; i++)); do
  id="${IDS[i]}" title="${TITLES[i]}" body="${BODIES[i]}"
  repo="$(repo_path "$id" "$TASK")"

  printf '%s\n' "${DIM}────────────────────────────────────────────────────────${R}"
  printf '%s  (%d/%d)\n' "${B}https://$HOST/$repo/issues${R}" "$((i + 1))" "$TOTAL"
  printf '%s\n\n' "${B}$title${R}"
  if [[ -n "$body" ]]; then
    printf '%s\n\n' "$body"
  else
    printf '%s\n\n' "${RED}(empty body)${R}"
  fi

  if [[ -z "$title" ]]; then
    echo "${RED}skipped: no issue title on the #$id# header line${R}"
    echo
    ((skipped++))
    continue
  fi
  if [[ -z "$body" ]]; then
    echo "${RED}skipped: empty body${R}"
    echo
    ((skipped++))
    continue
  fi

  if ((! DRY_RUN)); then
    dupe=$(gh issue list --repo "$HOST/$repo" --state all --limit 100 \
      --json number,title --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null |
      awk -F'\t' -v t="$title" '$2 == t { print $1; exit }')
    [[ -n "$dupe" ]] &&
      echo "${YELLOW}warning: issue #$dupe in $repo already has this title${R}"
  fi

  if ((DRY_RUN)); then
    echo "${DIM}would create${R}"
    echo
    ((pushed++))
    continue
  fi

  if ((ASSUME_YES)); then
    ans=""
  elif [[ -r /dev/tty ]]; then
    printf '%s' "Create this issue? [${B}Y${R}/n/q] "
    read -r ans </dev/tty || ans="q"
  else
    echo "Error: no terminal to confirm on — rerun with -y." >&2
    exit 1
  fi

  case "${ans,,}" in
    '' | y | yes)
      if url=$(printf '%s\n' "$body" |
        gh issue create --repo "$HOST/$repo" --title "$title" --body-file - 2>&1); then
        echo "${GREEN}created${R} $url"
        ((pushed++))
      else
        echo "${RED}FAILED${R} $repo"
        printf '    %s\n' "${url//$'\n'/$'\n'    }"
        ((failed++))
      fi
      ;;
    q | quit)
      echo "${YELLOW}aborted — remaining issues left alone${R}"
      aborted=$((TOTAL - i))
      break
      ;;
    *)
      echo "${DIM}skipped${R}"
      ((skipped++))
      ;;
  esac
  echo
done

printf '%s\n' "${DIM}────────────────────────────────────────────────────────${R}"
if ((DRY_RUN)); then
  echo "Dry run: $pushed/$TOTAL issue(s) ready to push, $skipped skipped."
else
  summary="Pushed $pushed/$TOTAL issues for $TASK."
  ((skipped)) && summary+=" $skipped skipped."
  ((aborted)) && summary+=" $aborted not reviewed."
  ((failed)) && summary+=" ${RED}$failed failed.${R}"
  echo "$summary"
fi

((failed == 0))
