#!/bin/bash
# run-board.sh - 在 Windows (Git Bash) 上通过 hdc 在主板运行 OHOS toybox 测试
#
# 前提:
#   1. hdc 能连到主板 (hdc list targets 能看到设备)
#   2. 主板已安装 toybox (默认路径 /system/bin/toybox)
#   3. Windows 有 Git Bash (需要 bash, diff)
#
# 用法:
#   export HDC=/path/to/hdc.exe
#   ./run-board.sh              # 跑全部 23 个测试
#   ./run-board.sh ls grep ps   # 跑指定命令
#
# 环境变量:
#   HDC          hdc 可执行文件路径 (默认 hdc)
#   TOYBOX_PATH  主板上 toybox 所在目录 (默认 /system/bin)
#   DEBUG=1      显示详细执行过程

TOP="$(cd "$(dirname "$0")" && pwd)"
TEST_OH_DIR="$TOP/test-oh"
SCRIPT_DIR="$TOP/scripts"
BOARD_DIR=/data/toybox-test

# 可配置: hdc 路径
HDC="${HDC:-hdc}"
# 可配置: 主板上 toybox 路径
TOYBOX_PATH="${TOYBOX_PATH:-/system/bin}"

echo "=========================================="
echo "  OHOS Toybox 板端测试运行器"
echo "  hdc:      $HDC"
echo "  测试目录: $TEST_OH_DIR"
echo "=========================================="

# 检查 hdc 连接
if ! "$HDC" list targets 2>&1 | grep -q "."; then
  echo "错误: hdc 未检测到主板"
  echo "请检查:"
  echo "  1. USB 是否连接"
  echo "  2. 'hdc list targets' 是否有输出"
  echo "  3. 如需启动: hdc start"
  exit 1
fi
echo "主板连接正常"

# ==== hdc 帮助函数 ====
# hdc.exe 在 Windows 上不传播远程退出码（永远返回 0），
# 所以不能依赖 $?，需要捕获输出检查错误信息。
# hdc_run CMD 返回 CMD 的执行输出（去掉末尾空行）
hdc_out() {
  "$HDC" shell "$@" 2>/dev/null | sed '$ { /^[[:space:]]*$/ d }'
}
# hdc_works: 命令输出中无错误信息即视为成功
hdc_works() {
  local out
  out=$(hdc_out "$1") || return 1
  case "$out" in
    *"inaccessible"*|*"not found"*|*"No such file"*) return 1 ;;
    "") return 1 ;;
  esac
  return 0
}
# hdc_cleanup: 清理板端测试内容，保留推送的 toybox 二进制
hdc_cleanup() {
  "$HDC" shell "cd $BOARD_DIR && ls -a 2>/dev/null | while read f; do case \"\$f\" in .|..|toybox) continue ;; esac; rm -rf \"\$f\"; done" 2>/dev/null
}

# 检查主板上 toybox 路径：优先用板端推送的（带 TOYBOX_OH_ADAPT）
if hdc_works "$BOARD_DIR/toybox --help"; then
  TOYBOX_CMD="$BOARD_DIR/toybox"
  echo "toybox 路径: $TOYBOX_CMD (推送版本)"
elif hdc_works "$TOYBOX_PATH/toybox --help"; then
  TOYBOX_CMD="$TOYBOX_PATH/toybox"
  echo "toybox 路径: $TOYBOX_CMD (系统版本)"
else
  echo "警告: 主板上未找到 toybox，尝试直接使用 (需在 PATH 中)"
  TOYBOX_CMD="toybox"
fi

# 清理板端工作目录（保留推送版 toybox），再确保目录存在
hdc_cleanup
"$HDC" shell "mkdir -p $BOARD_DIR" 2>/dev/null

# 检查主板上的 toybox 是否支持各命令
echo ""
echo "===== 检查主板命令支持 ====="
MISSING=0
for testfile in "$TEST_OH_DIR"/*.test; do
  CMDNAME="$(basename "${testfile%.test}")"
  if hdc_works "$TOYBOX_CMD $CMDNAME --help"; then
    echo "  [OK] $CMDNAME"
  else
    echo "  [--] $CMDNAME (不支持)"
    ((MISSING++))
  fi
done
[ $MISSING -gt 0 ] && echo "  $MISSING 个命令不被主板支持，对应的测试将被跳过"

# 加载测试框架
source "$SCRIPT_DIR/runtest.sh"
export OHOS_TEST=1
export SHOWSKIP=SKIP
export FAILCOUNT=0

# ====== 重写 testing()：bash 逻辑本地执行，命令通过 hdc 在主板直接执行 ======
testing() {
  wrong_args "$@"
  [ -z "$1" ] && NAME="$2" || NAME="$1"
  [ "${NAME#$CMDNAME }" == "$NAME" ] && NAME="$CMDNAME $1"
  [ -n "$DEBUG" ] && set -x

  if [ "$SKIP" -gt 0 ]; then
    verbose_has quiet || printf "%s\n" "$SHOWSKIP: $NAME"
    ((--SKIP)); return 0
  fi

  local TESTDIR="$TOP/_test/${CMDNAME}_$$"
  mkdir -p "$TESTDIR"

  # 写入期望结果和 input 文件（保持原 cwd，与原始 testing() 行为一致）
  echo -ne "$3" > "$TESTDIR/expected"
  [ -n "$4" ] && echo -ne "$4" > input || rm -f input

  # 构建远程命令：
  #   1. testcmd 调用 testing 时传的是 "\"$C\" args"，$2 含有引号
  #      这会在 Windows 命令行上被 hdc.exe 误解析，先去掉
  #   2. 替换 $C 为板端 toybox 路径
  REMOTE_CMD="$2"
  REMOTE_CMD="${REMOTE_CMD//\"$TOYBOX_CMD $CMDNAME\"/$TOYBOX_CMD $CMDNAME}"
  REMOTE_CMD="${REMOTE_CMD//\$C/$TOYBOX_CMD $CMDNAME}"

  # 同步测试创建的文件和目录到板端
  # Windows 上 echo > file 可能产生 CRLF，板端 cut -s 会对被抑制行
  # 也输出 \r\n，导致对比出现空行。对文本文件发送前 strip \r。
  # 二进制文件（含 NUL 字节的如 data.bz2、binary.txt）原样发送。
  for f in *; do
    [ -d "$f" ] && "$HDC" shell "mkdir -p $BOARD_DIR/$f" 2>/dev/null
    [ -f "$f" ] || continue
    local b64
    # 用 od 检测 NUL 字节（比 grep -P 更兼容，POSIX 平台通用）
    if od -A n -t x1 "$f" 2>/dev/null | grep -q ' 00'; then
      b64=$(base64 -w0 "$f" 2>/dev/null) || continue
    else
      b64=$(tr -d '\r' < "$f" | base64 -w0 2>/dev/null) || continue
    fi
    "$HDC" shell "printf '%s' '$b64' | $TOYBOX_CMD base64 -d > $BOARD_DIR/$f" 2>/dev/null
  done

  # 推送 stdin 文件（如有）
  if [ -n "$5" ]; then
    printf '%s' "$5" > "$TESTDIR/stdin"
    local b64
    b64=$(base64 -w0 "$TESTDIR/stdin" 2>/dev/null)
    "$HDC" shell "printf '%s' '$b64' | $TOYBOX_CMD base64 -d > $BOARD_DIR/stdin" 2>/dev/null
  fi

  # 直接在板端执行命令（保留末尾换行，$() 会吃掉，所以重定向到临时文件）
  if [ -n "$5" ]; then
    "$HDC" shell "cd $BOARD_DIR && $REMOTE_CMD < $BOARD_DIR/stdin" > "$TESTDIR/actual.raw" 2>/dev/null
  else
    "$HDC" shell "cd $BOARD_DIR && $REMOTE_CMD" > "$TESTDIR/actual.raw" 2>/dev/null
  fi
  RETVAL=$?
  tr -d '\r' < "$TESTDIR/actual.raw" > "$TESTDIR/actual"
  [ $RETVAL -gt 128 ] && echo "exited with signal (or returned $RETVAL)" >> "$TESTDIR/actual"

  DIFF="$(cd "$TESTDIR"; diff -au expected actual 2>&1)"
  [ -z "$DIFF" ] && do_pass || { VERBOSE=all do_fail; }

  if ! verbose_has quiet && { [ -n "$DIFF" ] || verbose_has spam; }; then
    [ -n "$4" ] && printf "%s\n" "echo -ne \"$4\" > input"
    printf "%s\n" "echo -ne '$5' | $REMOTE_CMD"
    [ -n "$DIFF" ] && printf "%s\n" "$DIFF"
  fi

  [ -n "$DIFF" ] && ! verbose_has all && exit 1
  rm -f input
  rm -rf "$TESTDIR"
  [ -n "$DEBUG" ] && set +x
  return 0
}

# ====== 遍历执行测试 ======
[ $# -eq 0 ] && set -- "$TEST_OH_DIR"/*.test

for testfile in "$@"; do
  CMDNAME="$(basename "${testfile%.test}")"

  # 检查主板是否支持该命令
  if ! hdc_works "$TOYBOX_CMD $CMDNAME --help"; then
    echo ""
    echo "=========================================="
    echo "  测试: $CMDNAME [跳过 - 主板不支持]"
    echo "=========================================="
    continue
  fi

  echo ""
  echo "=========================================="
  echo "  测试: $CMDNAME"
  echo "=========================================="

  C="$TOYBOX_CMD $CMDNAME"
  # 在干净的工作目录中运行测试，避免污染 $TOP
  # 测试创建的文件/目录会在此目录，testing() 只同步此目录内容
  WORKDIR="$TOP/_test/${CMDNAME}_work"
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  (
    cd "$WORKDIR"
    source "$TEST_OH_DIR/$CMDNAME.test"
    echo "$FAILCOUNT" > "$TOP/_test/${CMDNAME}_continue"
  ) || true

  if [ -f "$TOP/_test/${CMDNAME}_continue" ]; then
    FAILCOUNT=$(($(cat "$TOP/_test/${CMDNAME}_continue") + FAILCOUNT))
    rm -f "$TOP/_test/${CMDNAME}_continue"
  fi

  # 清理板端（保留推送版 toybox）
  hdc_cleanup
done

echo ""
echo "=========================================="
[ $FAILCOUNT -eq 0 ] && echo "  全部通过!" || echo "  失败: $FAILCOUNT"
echo "=========================================="
exit $FAILCOUNT
