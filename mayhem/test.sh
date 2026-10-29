#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TESTS="test/complex test/concurrency test/deparse test/deparse_depth test/fingerprint test/fingerprint_opts test/is_utility_stmt test/normalize test/normalize_utility test/parse test/parse_opts test/parse_protobuf test/parse_protobuf_opts test/scan test/split test/stack_depth test/summary test/summary_truncate"

passed=0; failed=0
log="$(mktemp)"; trap 'rm -f "$log"' EXIT

# Each upstream test binary compares pg_query's output against asserted expected values and exits
# non-zero on a mismatch. A binary that prints nothing never ran its assertions (e.g. it was
# stubbed to exit(0)), so empty output counts as a failure.
for t in $TESTS; do
  if [ ! -x "$t" ]; then echo "MISSING test binary $t (mayhem/build.sh should have built it)"; failed=$((failed+1)); continue; fi
  if "$t" > "$log" 2>&1 && [ -s "$log" ] && ! grep -qE 'FAIL|INVALID|UNEXPECTED' "$log"; then
    passed=$((passed+1)); echo "PASS $t"
  else
    failed=$((failed+1)); echo "FAIL $t"; tail -20 "$log"
  fi
done

# Golden-output test: the PL/pgSQL parse of test/plpgsql_samples.sql must equal the committed JSON.
rm -f test/plpgsql_samples.actual.json
if [ -x test/parse_plpgsql ] && test/parse_plpgsql > "$log" 2>&1 \
   && diff -u test/plpgsql_samples.expected.json test/plpgsql_samples.actual.json > "$log"; then
  passed=$((passed+1)); echo "PASS test/parse_plpgsql (golden JSON)"
else
  failed=$((failed+1)); echo "FAIL test/parse_plpgsql (golden JSON)"; head -40 "$log"
fi

emit_ctrf "libpg_query-make-test" "$passed" "$failed" 0
