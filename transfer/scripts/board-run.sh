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

# 详细日志
LOG_DIR=/data/toybox-test/logs
mkdir -p "$LOG_DIR"
TEST_LOG="$LOG_DIR/${CMDNAME}.log"
rm -f "$TEST_LOG"

# 被测命令：板端 toybox + 子命令
: "${TOYBOX:=/data/toybox-test/toybox}"
: "${OHOS_TEST:=1}"
: "${TESTDIR:=.}"
: "${VERBOSE:=all}"
: "${FAILCOUNT:=0}"

# 板端 hdc shell 的 PATH 可能缺少 testing() 与测试用例使用的裸命令
# (cmp/stat/cat/...)。先补全常见系统路径，再对仍缺失的命令兜底。
# 工具命令优先用系统 toybox（/system/bin/toybox 更完整），推送的 dev 构建可能缺命令。
SYS_TOYBOX=
for _st in /system/bin/toybox /system/xbin/toybox /vendor/bin/toybox; do
  [ -x "$_st" ] && SYS_TOYBOX="$_st" && break
done
[ -z "$SYS_TOYBOX" ] && SYS_TOYBOX="$TOYBOX"
for _p in /system/bin /system/xbin /vendor/bin /bin /usr/bin /sbin; do
  [ -d "$_p" ] && PATH="$_p:$PATH"
done
export PATH
# _util <cmd> <args...>: 按 PATH → 系统 toybox → 推送 toybox 顺序解析
_util() { "$@" 2>/dev/null || "$SYS_TOYBOX" "$@" 2>/dev/null || "$TOYBOX" "$@"; }
for _cmd in cmp stat readlink dd wc md5sum sha1sum sha256sum od hexdump \
             sort uniq tr cut sed grep egrep fgrep awk head tail find xargs \
             base64 sleep date truncate seq yes mktemp ln tee split comm paste \
             fold fmt expr factor iconv tty nohup timeout dirname basename \
             chattr lsattr more hexdump xxd; do
  command -v "$_cmd" >/dev/null 2>&1 || \
    eval "${_cmd}() { _util ${_cmd} \"\$@\"; }"
done
unset _cmd _p _st

export CMDNAME OHOS_TEST TOYBOX TESTDIR VERBOSE FAILCOUNT TEST_LOG

# 每条命令在独立干净工作目录执行，避免相互污染
WORKDIR=/data/toybox-test/work
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"
cd "$WORKDIR" || exit 127

# toybox 是 multicall 二进制：建立名为 $CMDNAME 的符号链接指向它，
# argv[0] 即命令名，toybox main.c 的 toy_find() 据此分发子命令。
# 这样 $C 是不含空格的单 token 路径，testcmd/testing 里 "\"$C\"" 的
# 引用约定才能正确工作（不能把 "toybox base32" 整体塞进 $C，
# 否则被当成带空格的单一文件名 -> "inaccessible or not found"）。
CMDLINK="$WORKDIR/$CMDNAME"
ln -sf "$TOYBOX" "$CMDLINK"
C="$CMDLINK"
export C

TEST_FILE="/data/toybox-test/test-oh/${CMDNAME}.test"
[ -f "$TEST_FILE" ] || { echo "board-run: 未找到测试文件 ${TEST_FILE}" >&2; exit 127; }

# 写入日志头
if [ -n "$TEST_LOG" ]; then
  {
    printf '# Command: %s\n' "$CMDNAME"
    printf '# Date: %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    printf '# Toybox: %s\n' "$TOYBOX"
    printf '# Toybox version: %s\n' "$("$TOYBOX" --version 2>/dev/null | head -1)"
    printf '# Kernel: %s\n' "$(uname -r 2>/dev/null)"
    printf '# Arch: %s\n' "$(uname -m 2>/dev/null)"
    printf '# OS: %s\n' "$(uname -o 2>/dev/null)"
    printf '# User: %s\n' "$(id 2>/dev/null)"
    printf '# Shell: %s\n' "$(readlink /proc/$$/exe 2>/dev/null || echo sh)"
    printf '# Hostname: %s\n' "$(hostname 2>/dev/null)"
    printf '# PATH: %s\n' "$PATH"
    printf '# TOYBOX path: %s\n' "$(readlink -f "$TOYBOX" 2>/dev/null || echo "$TOYBOX")"
    printf '# C (test cmd): %s\n' "$C"
    printf '# Workdir: %s\n' "$(pwd)"
    printf '\n'
  } > "$TEST_LOG"
fi

# VERBOSE=all 使首条失败后继续执行剩余用例
. "$TEST_FILE"

# 写入汇总
_log_summary

exit "${FAILCOUNT:-0}"
