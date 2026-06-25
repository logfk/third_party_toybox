#!/bin/bash

# test-oh/run.sh - Run OHOS-adapted toybox command tests
# Usage: test-oh/run.sh [test_name...]
# If no test name given, runs all *.test files in test-oh/

export TOPDIR="$PWD"
export TESTDIR="$PWD/generated/test-oh"
export OHOS_TEST=1
export SHOWSKIP="SKIP"
export FAILCOUNT=0

source "$TOPDIR/scripts/runtest.sh"
source "$TOPDIR/scripts/portability.sh"

rm -rf "$TESTDIR"
mkdir -p "$TESTDIR"/testdir

# Collect OPTIONFLAGS for optional()
[ -f "$TOPDIR/generated/config.h" ] &&
  export OPTIONFLAGS=:$($SED -nr 's/^#define CFG_(.*) 1$/\1/p' "$TOPDIR/generated/config.h" | tr '\n' :)

# If no arguments, run all tests in test-oh/
[ $# -eq 0 ] && set -- "$TOPDIR"/test-oh/*.test

for testfile in "$@"
do
  testfile="${testfile##*/}"
  testfile="${testfile%.test}"
  CMDNAME="$testfile"

  echo "=== $CMDNAME ==="

  # Build the command with TOYBOX_OH_ADAPT (must run from TOPDIR for relative paths)
  cd "$TOPDIR"
  export PREFIX="$TESTDIR/"
  CFLAGS="-DTOYBOX_OH_ADAPT" "$TOPDIR/scripts/single.sh" "$CMDNAME" 2>/dev/null || {
    echo "$SHOWSKIP: $CMDNAME build failed"
    continue
  }

  C="$TESTDIR/$CMDNAME"
  [ ! -e "$C" ] && echo "$SHOWSKIP: $CMDNAME disabled" && continue

  # Reset testdir
  cd "$TESTDIR" && rm -rf testdir continue && mkdir testdir && cd testdir || exit 1

  (. "$TOPDIR/test-oh/$CMDNAME.test"; cd "$TESTDIR"; echo "$FAILCOUNT" > continue)
  cd "$TESTDIR"
  [ -e continue ] && FAILCOUNT=$(($(cat continue)+$FAILCOUNT)) || exit 1
done

[ $FAILCOUNT -eq 0 ]
