#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harnesses and its test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

TESTS="test/complex test/concurrency test/deparse test/deparse_depth test/fingerprint test/fingerprint_opts test/is_utility_stmt test/normalize test/normalize_utility test/parse test/parse_opts test/parse_protobuf test/parse_protobuf_opts test/parse_plpgsql test/scan test/split test/stack_depth test/summary test/summary_truncate"

# The Makefile builds objects in-tree, so every phase starts from a clean object set (the .o/.a are
# gitignored; this also keeps a re-run after an edit from mixing sanitized and normal objects).
clean_objs() {
  find src vendor protobuf -name '*.o' -delete
  rm -f libpg_query.a
}

# 1) The project's own test suite, with NORMAL flags (no sanitizers, no debug override), left in test/.
clean_objs
rm -f $TESTS
env -u CFLAGS -u CXXFLAGS -u LDFLAGS make -j"$MAYHEM_JOBS" CFLAGS="$COVERAGE_FLAGS" TEST_CFLAGS="$COVERAGE_FLAGS" TEST_LDFLAGS="$COVERAGE_FLAGS" $TESTS

# 2) The sanitized, DWARF-3 library for the fuzz harnesses. Only UBSan's `function` check is relaxed:
#    the vendored Postgres node walkers call callbacks (stmts_walker, const_record_walker, ...) through a
#    cast `bool (*)(Node *, void *)` on every input, so it would halt before any real parsing happens.
#    ASan and every other UBSan check stay on and halting.
#    The library is also compiled with libFuzzer's coverage instrumentation (fuzzer-no-link) so the
#    engine can see inside it; without that only the 3-line harness is instrumented.
clean_objs
env -u CFLAGS -u CXXFLAGS -u LDFLAGS make -j"$MAYHEM_JOBS" build CFLAGS="$SANITIZER_FLAGS -fno-sanitize=function -fsanitize=fuzzer-no-link $DEBUG_FLAGS"

# 3) Harnesses (upstream's own test/fuzz/*.c, built unmodified): a libFuzzer binary and a
#    run-once standalone reproducer each, with leak detection switched off at build time.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$WORK/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o $WORK/standalone_main.o
for h in fuzz_parser fuzz_plpgsql fuzz_protobuf; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$SRC/test/fuzz/$h.c" -I"$SRC" \
      "$SRC/libpg_query.a" $WORK/lsan_off.o -pthread -lm -o "/mayhem/$h"
  $CC $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS "$SRC/test/fuzz/$h.c" -I"$SRC" $WORK/standalone_main.o \
      "$SRC/libpg_query.a" $WORK/lsan_off.o -pthread -lm -o "/mayhem/$h-standalone"
done
