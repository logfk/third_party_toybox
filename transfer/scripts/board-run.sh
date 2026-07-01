#!/bin/sh
# board-run.sh - 板端测试执行入口（由 run-board.sh 推送后调用）
#
# 设计目标：让测试的 setup(touch/chmod/rm/readlink ...) 与被测命令 $C
# 运行在同一环境（板端），消除“本地 setup + 板端执行”导致的状态/路径错配。
#
# 调用方式（由 run-board.sh 通过 hdc shell 执行）:
#   cd /data/toybox-test &&
#   CMDNAME=cp OHOS_TEST=1 TOYBOX=/data/toybox-test/toybox \
#   FILES=/data/toybox-test/files TESTDIR=. FAILCOUNT=0 VERBOSE=all \
#   sh /data/toybox-test/board-run.sh cp
#
# 输出：直接打印 PASS/FAIL/SKIP 及失败 diff（供 Windows 端 gen-report.sh 解析）。

# 测试框架（testing/testcmd/ohosonly/skipnot ...）
. /data/toybox-test/testing.sh

CMDNAME="$1"
[ -n "$CMDNAME" ] || { echo "board-run: 缺少命令名参数" >&2; exit 127; }

# 被测命令：板端 toybox + 子命令
: "${TOYBOX:=/data/toybox-test/toybox}"
: "${OHOS_TEST:=1}"
: "${TESTDIR:=.}"
: "${VERBOSE:=all}"
: "${FAILCOUNT:=0}"

C="${TOYBOX} ${CMDNAME}"
export CMDNAME C OHOS_TEST TOYBOX TESTDIR VERBOSE FAILCOUNT

# 每条命令在独立干净工作目录执行，避免相互污染
WORKDIR=/data/toybox-test/work
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 127

TEST_FILE="/data/toybox-test/test-oh/${CMDNAME}.test"
[ -f "$TEST_FILE" ] || { echo "board-run: 未找到测试文件 ${TEST_FILE}" >&2; exit 127; }

# VERBOSE=all 使首条失败后继续执行剩余用例
. "$TEST_FILE"

exit "${FAILCOUNT:-0}"
