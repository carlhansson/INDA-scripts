#!/usr/bin/env bash
#   ./run-tests.sh task-1                    run 0-master/task-1's tests on every student's task-1
#   ./run-tests.sh task-1 carlhans meya      only test the listed students
#   ./run-tests.sh -s carlhans,meya task-1   same, with -s
#   ./run-tests.sh -f task-1                 fetch the tests again, then run them
set -uo pipefail

MASTER_DIR="./0-master"          # folder holding <task-name>/ inda master git repo with solutions branch
LIB_DIRS=("." "/usr/share/java") # searched in order for junit*.jar and hamcrest*.jar
TEST_TIMEOUT=10                  # seconds a single test may run before it counts as failed

HOST="gits-15.sys.kth.se" # GitHub Enterprise hostname
ORG="inda-master"         # organization owning the master repos
BRANCH="solutions"        # branch in the master repo that holds the tests

STUDENTS_FILE="students.txt"

usage() {
  cat <<EOF
Usage: ${0##*/} [-f] [-s student-id[,student-id ...]] <task-name> [student-id ...]

Runs every *Test.java under $MASTER_DIR/<task-name>/ against each student's
./<student-id>/<task-name>/ and prints a report with one section per student.

If $MASTER_DIR/<task-name>/ has no *Test.java files, the $BRANCH branch of
git@$HOST:$ORG/<task-name>.git is cloned there first.

A test file tests the student file with the same name minus "Test", at the same
relative path: src/HelloWorldTest.java tests ./<student-id>/<task-name>/src/HelloWorld.java.
If the file is somewhere else in the repo, that copy is tested and a note is shown.

Students are the ids given with -s and/or after the task name, or every id in ./$STUDENTS_FILE
(one id per row). JUnit 4 and Hamcrest jars are taken from the first folder
that has them, in this order: ${LIB_DIRS[*]}

Options:
  -f    Fetch the tests again from the $BRANCH branch, even if they
        are already in $MASTER_DIR/<task-name>/
  -s    Only test these students instead of everyone in $STUDENTS_FILE;
        separate ids with commas or spaces, or repeat -s
  -h    Show this help

Master folder, jar folders, the per-test timeout and the git host, organization
and branch are set in the configuration block at the top of the script.
EOF
}

REFETCH=0
ONLY=()
while getopts ':hfs:' opt; do
  case "$opt" in
    h)
      usage
      exit 0
      ;;
    f) REFETCH=1 ;;
    s)
      read -ra ids <<<"${OPTARG//,/ }"
      ONLY+=("${ids[@]}")
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

(($# >= 1)) || {
  echo "Error: a task name is required." >&2
  usage >&2
  exit 2
}
TASK="$1"
shift
TEST_ROOT="$MASTER_DIR/$TASK"

has_tests() { # true if TEST_ROOT has at least one *Test.java
  [[ -n $(find "$TEST_ROOT" -name .git -prune -o -type f -name '*Test.java' -print -quit 2>/dev/null) ]]
}

fetch_tests() { # clones TEST_ROOT, or resets an existing clone to the latest $BRANCH
  local url="git@$HOST:$ORG/$TASK.git"
  command -v git >/dev/null || {
    echo "Error: git not found." >&2
    return 1
  }
  if [[ -d "$TEST_ROOT/.git" ]]; then
    echo "Fetching $BRANCH from $url into $TEST_ROOT" >&2
    git -C "$TEST_ROOT" fetch -q origin "$BRANCH" &&
      git -C "$TEST_ROOT" checkout -q -f -B "$BRANCH" FETCH_HEAD
  elif [[ -e "$TEST_ROOT" ]]; then
    echo "Error: $TEST_ROOT exists but is not a git repo; move it away to fetch the tests." >&2
    return 1
  else
    echo "Cloning $BRANCH from $url into $TEST_ROOT" >&2
    mkdir -p "$MASTER_DIR" &&
      git clone -q --branch "$BRANCH" "$url" "$TEST_ROOT"
  fi
}

if ((REFETCH)) || ! has_tests; then
  fetch_tests || {
    echo "Error: could not fetch the tests for $TASK." >&2
    exit 1
  }
fi

command -v javac >/dev/null && command -v java >/dev/null ||
  {
    echo "Error: java/javac not found." >&2
    exit 2
  }

find_jars() { # every jar matching $1 in the first of LIB_DIRS that has one
  local dir jar found=()
  for dir in "${LIB_DIRS[@]}"; do
    for jar in "$dir"/$1; do
      [[ -f "$jar" ]] && found+=("$(realpath "$jar")")
    done
    ((${#found[@]})) && {
      printf '%s\n' "${found[@]}" | sort -u
      return 0
    }
  done
  return 1
}

JUNIT=$(find_jars 'junit*.jar') || {
  echo "Error: no junit*.jar in ${LIB_DIRS[*]}." >&2
  exit 2
}
HAMCREST=$(find_jars 'hamcrest*.jar') || {
  echo "Error: no hamcrest*.jar in ${LIB_DIRS[*]}." >&2
  exit 2
}
CP=$(printf '%s\n' "$JUNIT" "$HAMCREST" | paste -sd: -)

ONLY+=("$@")
if ((${#ONLY[@]})); then
  mapfile -t STUDENTS < <(printf '%s\n' "${ONLY[@]}" | awk 'NF && !seen[$1]++ { print $1 }')
else
  [[ -r "$STUDENTS_FILE" ]] || {
    echo "Error: no readable $STUDENTS_FILE in $PWD." >&2
    exit 1
  }
  mapfile -t STUDENTS < <(
    sed -e 's/\r$//' -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      "$STUDENTS_FILE" | grep -v '^$' | awk '!seen[$0]++'
  )
  ((${#STUDENTS[@]})) || {
    echo "Error: no student ids in $STUDENTS_FILE." >&2
    exit 1
  }
fi

mapfile -t TESTS < <(
  cd "$TEST_ROOT" && find . -name .git -prune -o -type f -name '*Test.java' -print | sed 's|^\./||' | sort
)
((${#TESTS[@]})) || {
  echo "Error: no *Test.java files in $TEST_ROOT." >&2
  exit 1
}

declare -A EXPECTED # @Test count per file, used when a test class can't run at all
for rel in "${TESTS[@]}"; do
  EXPECTED[$rel]=$(($(grep -v '^[[:space:]]*//' "$TEST_ROOT/$rel" | grep -oE '@Test([^[:alnum:]_]|$)' | wc -l)))
done

if [[ -t 1 ]]; then
  B=$(tput bold) DIM=$(tput dim) R=$(tput sgr0)
  RED=$(tput setaf 1) GREEN=$(tput setaf 2) YELLOW=$(tput setaf 3)
else
  B='' DIM='' R='' RED='' GREEN='' YELLOW=''
fi

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

# test runner: runs one JUnit 4 test class, fails any test that runs longer than
# TEST_TIMEOUT, and prints one tab-separated line per event on the real stdout:
#   COUNT <n> | PASS <test> | FAIL <test> <error> | SKIP <test> | ABORT <test> <why> | DONE
# newlines, tabs and backslashes inside <error> are escaped as \n, \t and \\

mkdir -p "$WORK/runner/testrunner"
cat >"$WORK/runner/testrunner/Main.java" <<'JAVA'
package testrunner;

import java.io.OutputStream;
import java.io.PrintStream;
import java.util.concurrent.TimeUnit;
import org.junit.internal.runners.statements.FailOnTimeout;
import org.junit.runner.Description;
import org.junit.runner.JUnitCore;
import org.junit.runner.Request;
import org.junit.runner.notification.Failure;
import org.junit.runner.notification.RunListener;
import org.junit.runners.BlockJUnit4ClassRunner;
import org.junit.runners.model.FrameworkMethod;
import org.junit.runners.model.InitializationError;
import org.junit.runners.model.Statement;

public class Main {
    static final PrintStream OUT = System.out;    // saved before student code can redirect System.out
    static volatile String running = null;
    static volatile boolean done = false;
    static String testClass;

    public static void main(String[] args) {
        testClass = args[0];
        long timeout = Long.parseLong(args[1]);
        System.setOut(new PrintStream(OutputStream.nullOutputStream()));    // stray prints stay out of our lines
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            if (!done) emit("ABORT", running, "the JVM exited before the run finished (System.exit?)");
        }));

        try {
            TimedRunner runner = new TimedRunner(Class.forName(testClass), timeout);
            emit("COUNT", String.valueOf(runner.testCount()));
            JUnitCore core = new JUnitCore();
            core.addListener(new Listener());
            core.run(Request.runner(runner));
        } catch (InitializationError e) {
            for (Throwable cause : e.getCauses()) emit("FAIL", "(test class)", describe(cause));
        } catch (Throwable t) {
            emit("FAIL", "(test class)", describe(t));
        }
        done = true;
        emit("DONE");
        System.exit(0);    // also ends threads left running by timed-out tests
    }

    static class TimedRunner extends BlockJUnit4ClassRunner {
        final long timeout;

        TimedRunner(Class<?> cls, long timeout) throws InitializationError {
            super(cls);
            this.timeout = timeout;
        }

        // the whole test runs under the time limit, including creating the test object
        @Override protected Statement methodBlock(FrameworkMethod method) {
            Statement test = new Statement() {
                @Override public void evaluate() throws Throwable {
                    TimedRunner.super.methodBlock(method).evaluate();
                }
            };
            return FailOnTimeout.builder().withTimeout(timeout, TimeUnit.SECONDS).build(test);
        }
    }

    static class Listener extends RunListener {
        final StringBuilder errors = new StringBuilder();

        @Override public void testStarted(Description d) {
            running = d.getMethodName();
            errors.setLength(0);
        }
        @Override public void testFailure(Failure f) {
            if (running == null) {    // failure outside a test, e.g. in @BeforeClass
                emit("FAIL", "(whole class)", describe(f.getException()));
                return;
            }
            if (errors.length() > 0) errors.append('\n');
            errors.append(describe(f.getException()));
        }
        @Override public void testIgnored(Description d) {
            emit("SKIP", d.getMethodName());
        }
        @Override public void testFinished(Description d) {
            if (errors.length() == 0) emit("PASS", d.getMethodName());
            else emit("FAIL", d.getMethodName(), errors.toString());
            running = null;
        }
    }

    // the error message, then the stack frames in student/test code down to the test method
    static String describe(Throwable t) {
        StringBuilder sb = new StringBuilder();
        Throwable root = t;
        for (Throwable c = t; c != null && sb.length() < 1500; c = c.getCause()) {
            if (c != t) sb.append("\ncaused by: ");
            boolean plain = c.getMessage() != null
                && (c instanceof AssertionError || c.getClass().getName().startsWith("org.junit."));
            sb.append((plain ? c.getMessage() : c.toString()).strip());
            root = c;
        }
        if (sb.length() > 1500) sb.replace(1500, sb.length(), " ...(truncated)");

        String previous = "";
        int shown = 0;
        for (StackTraceElement e : root.getStackTrace()) {
            String cls = e.getClassName();
            if (cls.matches("(java|javax|jdk|sun|com\\.sun|org\\.junit|junit|org\\.hamcrest|testrunner)\\..*")) continue;
            String frame = cls + "." + e.getMethodName() + "(" + e.getFileName() + ":" + e.getLineNumber() + ")";
            if (!frame.equals(previous)) { sb.append("\nat ").append(frame); shown++; }
            previous = frame;
            if (shown == 4 || cls.equals(testClass) || cls.startsWith(testClass + "$")) break;
        }
        return sb.toString();
    }

    static synchronized void emit(String... fields) {
        StringBuilder line = new StringBuilder();
        for (String f : fields) {
            if (line.length() > 0) line.append('\t');
            if (f == null || f.isEmpty()) f = "?";
            line.append(f.replace("\\", "\\\\").replace("\r", "").replace("\n", "\\n").replace("\t", "\\t"));
        }
        OUT.println(line);
        OUT.flush();
    }
}
JAVA

if ! err=$(javac -encoding UTF-8 -nowarn -d "$WORK/runner" -cp "$CP" "$WORK/runner/testrunner/Main.java" 2>&1); then
  echo "Error: could not build the test runner with $CP (JUnit 4 is needed):" >&2
  printf '    %s\n' "${err//$'\n'/$'\n'    }" >&2
  exit 2
fi

with_timeout() { # <seconds> <command...>, runs without a limit where coreutils timeout is missing
  if command -v timeout >/dev/null; then timeout -k 5 "$@"; else
    shift
    "$@"
  fi
}

run_one() { # <student> <test path relative to TEST_ROOT> <expected test count>
  local student="$1" rel="$2" expected="$3" repo="$1/$TASK"
  local dir target wanted found hint base
  dir=$(dirname "$rel")
  target="$(basename "$rel" Test.java).java"
  wanted="${dir#.}/$target"
  wanted="${wanted#/}"
  base="$WORK/$student/${rel//\//__}"
  mkdir -p "$base.classes"

  found="$repo/$wanted"
  if [[ ! -f "$found" ]]; then
    found=$(find "$repo" -name .git -prune -o -type f -name "$target" -print | sort | head -n 1)
    if [[ -z "$found" ]]; then
      hint=$(find "$repo" -name .git -prune -o -type f -iname "$target" -print | sort | head -n 1)
      printf 'MISSING\t%s\t%s\n' "$wanted" "${hint#"$repo/"}" >"$base.out"
      return 0
    fi
    printf 'MOVED\t%s\t%s\n' "${found#"$repo/"}" "$wanted" >"$base.out"
  fi

  # -sourcepath is the student's folder only, so the master's own solutions are never picked up
  if ! javac -encoding UTF-8 -nowarn -d "$base.classes" -cp "$CP" \
    -sourcepath "$(dirname "$found")" "$TEST_ROOT/$rel" >"$base.javac" 2>&1; then
    echo "COMPILE" >>"$base.out"
    return 0
  fi

  (cd "$(dirname "$found")" &&
    with_timeout $((TEST_TIMEOUT * (expected + 2) + 30)) \
      java -Xmx512m -Djava.awt.headless=true -cp "$base.classes:$WORK/runner:$CP" \
      testrunner.Main "$(basename "$rel" .java)" "$TEST_TIMEOUT") >>"$base.out" 2>"$base.err"
  printf 'EXIT\t%s\n' "$?" >>"$base.out"
}

export -f run_one with_timeout
export TASK TEST_ROOT TEST_TIMEOUT WORK CP

JOBS=$({ nproc || sysctl -n hw.ncpu; } 2>/dev/null || echo 4)
[[ -t 2 ]] && PROGRESS=1 || PROGRESS=""
export PROGRESS

echo "$TASK: ${#STUDENTS[@]} students, ${#TESTS[@]} test file(s), $JOBS parallel jobs"
echo "${DIM}tests     $TEST_ROOT: ${TESTS[*]}${R}"
echo "${DIM}junit     ${JUNIT//$'\n'/ }${R}"
echo "${DIM}hamcrest  ${HAMCREST//$'\n'/ }${R}"
echo

[[ -n "$PROGRESS" ]] && printf 'running tests ' >&2
for student in "${STUDENTS[@]}"; do
  [[ -d "$student/$TASK" ]] || continue
  for rel in "${TESTS[@]}"; do
    printf '%s\0%s\0%s\0' "$student" "$rel" "${EXPECTED[$rel]}"
  done
done | xargs -0 -r -P "$JOBS" -n 3 bash -c 'run_one "$@"; [[ -z "$PROGRESS" ]] || printf . >&2' _
[[ -n "$PROGRESS" ]] && printf '\r\033[K' >&2

# report

report_test() { # <student> <test path>: appends to SECTION and the student's S_* counts and notes
  local student="$1" rel="$2" name base kind a b line lines total color
  local count="" passed=0 skipped=0 finished=0 exit_code="?" compiled=1
  local missing="" hint="" moved="" wanted="" stopped_in="" stopped_why="" where="" fails="" status="" detail=""
  name=$(basename "$rel" .java)
  base="$WORK/$student/${rel//\//__}"

  [[ -f "$base.out" ]] || : >"$base.out"
  while IFS=$'\t' read -r kind a b; do
    case "$kind" in
      MISSING) missing="$a" hint="$b" ;;
      MOVED) moved="$a" wanted="$b" ;;
      COMPILE) compiled=0 ;;
      COUNT) count="$a" ;;
      PASS) ((passed++)) ;;
      SKIP) ((skipped++)) ;;
      FAIL)
        b=$(printf '%b' "$b")
        fails+="    ${RED}FAIL${R} $a"$'\n'"         ${b//$'\n'/$'\n'         }"$'\n'
        ;;
      ABORT) stopped_in="$a" stopped_why=$(printf '%b' "$b") ;;
      DONE) finished=1 ;;
      EXIT) exit_code="$a" ;;
    esac
  done <"$base.out"

  total=$((${count:-${EXPECTED[$rel]}} - skipped))

  if [[ -n "$missing" ]]; then
    status="missing $missing"
    [[ -n "$hint" ]] && status+=" (found $hint)"
    S_MISSING+=" ${missing##*/}"
  elif ((! compiled)); then
    status="compile error"
    detail=$(<"$base.javac")
    lines=$(wc -l <"$base.javac")
    ((lines > 40)) && detail="$(head -n 30 "$base.javac")"$'\n'"... ($((lines - 30)) more lines)"
    S_NOCOMPILE+=" $name"
  elif ((! finished)); then
    [[ -n "$stopped_in" && "$stopped_in" != "?" ]] && where=" in $stopped_in"
    if [[ "$exit_code" == 124 || "$exit_code" == 137 ]]; then # timeout's SIGTERM also fires the ABORT hook
      status="killed$where: the run went over its time limit"
    elif [[ -n "$stopped_why" ]]; then
      status="stopped$where: $stopped_why"
    else
      status="crashed (exit $exit_code)"
      detail=$(tail -n 5 "$base.err" 2>/dev/null)
    fi
    S_UNFINISHED+=" $name"
  fi
  [[ -n "$moved" ]] && S_MISPLACED+=" ${moved##*/}"

  color="$GREEN"
  if [[ -n "$status" ]] || ((passed < total)); then
    color="$RED"
    S_BAD=1
  fi
  ((total < passed)) && total=$passed
  ((skipped)) && status+="${status:+, }$skipped ignored"

  printf -v line '  %-*s  %s%5s%s%s\n' "$W" "$name" "$color" "$passed/$total" "${status:+  $status}" "$R"
  SECTION+="$line"
  [[ -n "$moved" ]] && SECTION+="    ${YELLOW}note: no $wanted, tested $moved instead${R}"$'\n'
  [[ -n "$detail" ]] && SECTION+="      ${detail//$'\n'/$'\n'      }"$'\n'
  SECTION+="$fails"
  ((S_PASS += passed, S_TOTAL += total))
}

SEP="${DIM}────────────────────────────────────────────────────────${R}"
W=0
for rel in "${TESTS[@]}"; do
  n=$(basename "$rel" .java)
  ((${#n} > W)) && W=${#n}
done
SW=0
for student in "${STUDENTS[@]}"; do ((${#student} > SW)) && SW=${#student}; done

SUMMARY="" perfect=0

for student in "${STUDENTS[@]}"; do
  echo "$SEP"
  if [[ ! -d "$student/$TASK" ]]; then
    echo "${B}$student${R}  ${RED}no repo at ./$student/$TASK${R}"
    echo
    printf -v line '  %-*s  %s%5s  %s%s\n' "$SW" "$student" "$RED" "-" "no repo" "$R"
    SUMMARY+="$line"
    continue
  fi

  SECTION="" S_PASS=0 S_TOTAL=0 S_BAD=0 S_MISSING="" S_NOCOMPILE="" S_UNFINISHED="" S_MISPLACED=""
  for rel in "${TESTS[@]}"; do
    report_test "$student" "$rel"
  done

  color="$GREEN"
  if ((S_BAD)); then color="$RED"; else ((perfect++)); fi
  echo "${B}$student${R}  $color$S_PASS/$S_TOTAL tests passed$R"
  printf '%s\n' "$SECTION"

  notes=""
  [[ -n "$S_MISSING" ]] && notes+="; missing:$S_MISSING"
  [[ -n "$S_NOCOMPILE" ]] && notes+="; compile error:$S_NOCOMPILE"
  [[ -n "$S_UNFINISHED" ]] && notes+="; did not finish:$S_UNFINISHED"
  [[ -n "$S_MISPLACED" ]] && notes+="; misplaced:$S_MISPLACED"
  notes="${notes#; }"
  printf -v line '  %-*s  %s%5s%s%s\n' "$SW" "$student" "$color" "$S_PASS/$S_TOTAL" "${notes:+  $notes}" "$R"
  SUMMARY+="$line"
done

echo "$SEP"
echo "${B}$TASK summary${R}: $perfect/${#STUDENTS[@]} students passed every test"
printf '%s' "$SUMMARY"
