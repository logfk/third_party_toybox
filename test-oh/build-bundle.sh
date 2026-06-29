#!/bin/bash
# test-oh/build-bundle.sh - 在 Linux VM 上交叉编译所有测试，打包为 Windows 可用 bundle
# 用法:  test-oh/build-bundle.sh
# 输出:  test-oh-arm-bundle.tar.gz  (传到 Windows 解压即用)

set -e

TOP="$(cd "$(dirname "$0")/.." && pwd)"

# ====== 工具链配置（按实际路径修改） ======
TOOLCHAIN=/srv/workspace/openharmony_master_default_20260624175729_huawei_5a33ef946/code/prebuilts/clang/ohos/linux-x86_64/llvm/bin
SYSROOT=/srv/workspace/openharmony_master_default_20260624175729_huawei_5a33ef946/code/prebuilts/ohos-sdk/linux/26/native/sysroot

export PATH="$TOOLCHAIN:$PATH"
export CC=clang
export CROSS_COMPILE=armv7-unknown-linux-ohos-
export CFLAGS="-DTOYBOX_OH_ADAPT --sysroot=$SYSROOT -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types"
export LDFLAGS="--sysroot=$SYSROOT -L$SYSROOT/usr/lib/arm-linux-ohos"

BUNDLE_DIR="/tmp/toybox-board-bundle"
BIN_DIR="$BUNDLE_DIR/bin"
TEST_OH_DIR="$BUNDLE_DIR/test-oh"
SCRIPT_DIR="$BUNDLE_DIR/scripts"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BIN_DIR" "$TEST_OH_DIR" "$SCRIPT_DIR"

cd "$TOP"
# 生成默认 .config（如没有）
[ ! -f .config ] && make defconfig >/dev/null 2>&1
# 禁用某些选项以确保编译通过
sed -i '/CONFIG_\(LOGIN\|LOGIN_SHADOW\|UPTIME\|W\|PING\|NETCAT\|WHO\)=y/s/=y/# & is not set/' .config 2>/dev/null || true

echo "===== 交叉编译 23 个测试命令 ====="
COUNT=0
for testfile in test-oh/*.test; do
  CMDNAME="$(basename "${testfile%.test}")"
  echo -n "  [$((++COUNT))/23] $CMDNAME ... "

  mkdir -p "$BIN_DIR"
  PREFIX="$BIN_DIR/" scripts/single.sh "$CMDNAME" >/dev/null 2>&1 && {
    file "$BIN_DIR/$CMDNAME" | grep -q "ELF" && echo "OK" || { echo "FAIL (not ELF)"; false; }
  } || {
    echo "SKIP (build failed)"
  }
done

echo ""
echo "===== 打包 bundle ====="

# 复制 .test 文件
cp test-oh/*.test "$TEST_OH_DIR/"
# 复制测试框架
cp scripts/runtest.sh "$SCRIPT_DIR/"
# 复制 config.h（供 OPTIONFLAGS 分析）
[ -f generated/config.h ] && cp generated/config.h "$SCRIPT_DIR/"

# 生成 run-board.sh（Windows 端执行器）
cat > "$BUNDLE_DIR/run-board.sh" << 'RUNEOF'
#!/bin/bash
# run-board.sh - 在 Windows (Git Bash/MSYS2/WSL) 上通过 hdc 推送并执行测试
# 使用 build-bundle.sh 预编译的 ARM 二进制
#
# 前置条件: hdc 已配置并连接到主板
# 用法:     ./run-board.sh [test_name...]
# 首次需配置 HDC:  export HDC=/path/to/hdc.exe

TOP="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$TOP/bin"
TEST_OH_DIR="$TOP/test-oh"
SCRIPT_DIR="$TOP/scripts"
BOARD_DIR=/data/toybox-test

# hdc 路径 - 用户需根据实际位置设置
HDC="${HDC:-hdc}"

# 板端系统 toybox 路径（用于 base64 解码等基础工具）
SYS_TOYBOX="${SYS_TOYBOX:-/system/bin/toybox}"

echo "===== 板端测试运行器 ====="
echo "  HDC:       $HDC"
echo "  BOARD_DIR: $BOARD_DIR"
echo "  测试数:    $# 个"

# 检查主板连接
"$HDC" list targets 2>&1 | grep -q "." || {
  echo "错误: 未检测到主板 (hdc list targets 为空)"
  echo "请确认: 1) USB 已连接  2) hdc 路径正确  3) hdc start 已运行"
  exit 1
}

# 分两步清理，避免 && 被 hdc.exe 吞掉
"$HDC" shell "rm -rf $BOARD_DIR" 2>/dev/null
"$HDC" shell "mkdir -p $BOARD_DIR" 2>/dev/null

# 推送全部预编译二进制（用 base64 传输，避免 hdc file send 路径问题）
echo "===== 推送二进制到主板 ====="
BIN_COUNT=0
for f in "$BIN_DIR"/*; do
  [ -f "$f" ] || continue
  CMDNAME="$(basename "$f")"
  echo "  [推送] $CMDNAME"
  local b64
  b64=$(base64 -w0 "$f" 2>/dev/null) || continue
  "$HDC" shell "printf '%s' '$b64' | $SYS_TOYBOX base64 -d > $BOARD_DIR/$CMDNAME" 2>/dev/null
  "$HDC" shell "chmod +x $BOARD_DIR/$CMDNAME" 2>/dev/null
  ((BIN_COUNT++))
done
echo "  共推送 $BIN_COUNT 个命令"

# 准备测试环境变量
export TOPDIR="$TOP"
export OHOS_TEST=1
export SHOWSKIP=SKIP
export FAILCOUNT=0

# 加载测试框架
source "$SCRIPT_DIR/runtest.sh"

# OPTIONFLAGS
[ -f "$SCRIPT_DIR/config.h" ] &&
  export OPTIONFLAGS=:$(sed -n 's/^#define CFG_\(.*\) 1$/\1/p' "$SCRIPT_DIR/config.h" | tr '\n' :)

# 如果无参数，跑全部
[ $# -eq 0 ] && set -- "$TEST_OH_DIR"/*.test

# ====== 重写 testing()：通过 hdc 在板端执行命令 ======
testing() {
  wrong_args "$@"
  [ -z "$1" ] && NAME="$2" || NAME="$1"
  [ "${NAME#$CMDNAME }" == "$NAME" ] && NAME="$CMDNAME $1"
  [ -n "$DEBUG" ] && set -x

  if [ "$SKIP" -gt 0 ]; then
    verbose_has quiet || printf "%s\n" "$SHOWSKIP: $NAME"
    ((--SKIP)); return 0
  fi

  local TESTDIR="$TOPDIR/_test/${CMDNAME}_$$"
  mkdir -p "$TESTDIR"

  # 写入期望结果
  echo -ne "$3" > "$TESTDIR/expected"
  [ -n "$4" ] && echo -ne "$4" > input || rm -f input

  # 构建远程命令：去掉 testcmd 加的引号，替换 $C
  REMOTE_CMD="$2"
  REMOTE_CMD="${REMOTE_CMD//\"$BOARD_DIR\/$CMDNAME\"/$BOARD_DIR\/$CMDNAME}"
  REMOTE_CMD="${REMOTE_CMD//\$C/$BOARD_DIR\/$CMDNAME}"

  # 同步测试创建的文件到板端（base64 传输）
  for f in *; do
    [ -d "$f" ] && "$HDC" shell "mkdir -p $BOARD_DIR/$f" 2>/dev/null
    [ -f "$f" ] || continue
    local b64
    # 二进制文件（含 NUL 字节）原样发送，文本文件 strip \r
    if od -A n -t x1 "$f" 2>/dev/null | grep -q ' 00'; then
      b64=$(base64 -w0 "$f" 2>/dev/null) || continue
    else
      b64=$(tr -d '\r' < "$f" | base64 -w0 2>/dev/null) || continue
    fi
    "$HDC" shell "printf '%s' '$b64' | $SYS_TOYBOX base64 -d > $BOARD_DIR/$f" 2>/dev/null
  done

  # 推送 stdin（base64 传输，避免 hdc.exe 的 stdin pipe hang）
  if [ -n "$5" ]; then
    printf '%s' "$5" > "$TESTDIR/stdin"
    local b64
    b64=$(base64 -w0 "$TESTDIR/stdin" 2>/dev/null)
    "$HDC" shell "printf '%s' '$b64' | $SYS_TOYBOX base64 -d > $BOARD_DIR/stdin" 2>/dev/null
  fi

  # 在板端执行（重定向到文件，保留末尾换行）
  if [ -n "$5" ]; then
    "$HDC" shell "cd $BOARD_DIR && $REMOTE_CMD < $BOARD_DIR/stdin" > "$TESTDIR/actual.raw" 2>/dev/null
  else
    "$HDC" shell "cd $BOARD_DIR && $REMOTE_CMD" > "$TESTDIR/actual.raw" 2>/dev/null
  fi
  RETVAL=$?
  # strip \r 处理板端 CRLF
  tr -d '\r' < "$TESTDIR/actual.raw" > "$TESTDIR/actual"
  [ $RETVAL -gt 128 ] && echo "exited with signal (or returned $RETVAL)" >> "$TESTDIR/actual"

  # 比对
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
for testfile in "$@"; do
  CMDNAME="$(basename "${testfile%.test}")"
  echo ""
  echo "=========================================="
  echo "  测试: $CMDNAME"
  echo "=========================================="

  # 检查二进制是否存在
  "$HDC" shell "[ -f $BOARD_DIR/$CMDNAME ]" 2>/dev/null || {
    echo "  [跳过] 二进制 $CMDNAME 不在板端"
    continue
  }

  # 在干净的工作目录中运行测试
  C="$BOARD_DIR/$CMDNAME"
  WORKDIR="$TOPDIR/_test/${CMDNAME}_work"
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  (
    cd "$WORKDIR"
    source "$TEST_OH_DIR/$CMDNAME.test"
    echo "$FAILCOUNT" > "$TOPDIR/_test/${CMDNAME}_continue"
  ) || true

  if [ -f "$TOPDIR/_test/${CMDNAME}_continue" ]; then
    FAILCOUNT=$(($(cat "$TOPDIR/_test/${CMDNAME}_continue") + FAILCOUNT))
    rm -f "$TOPDIR/_test/${CMDNAME}_continue"
  fi

  # 清理板端（分两步，避免 && 被吞）
  "$HDC" shell "rm -rf $BOARD_DIR" 2>/dev/null
  "$HDC" shell "mkdir -p $BOARD_DIR" 2>/dev/null

  # 恢复二进制
  for f in "$BIN_DIR"/*; do
    [ -f "$f" ] || continue
    CMDNAME="$(basename "$f")"
    local b64
    b64=$(base64 -w0 "$f" 2>/dev/null) || continue
    "$HDC" shell "printf '%s' '$b64' | $SYS_TOYBOX base64 -d > $BOARD_DIR/$CMDNAME" 2>/dev/null
    "$HDC" shell "chmod +x $BOARD_DIR/$CMDNAME" 2>/dev/null
  done
done

echo ""
echo "=========================================="
[ $FAILCOUNT -eq 0 ] && echo "  全部通过!" || echo "  失败: $FAILCOUNT"
echo "=========================================="
exit $FAILCOUNT
RUNEOF
chmod +x "$BUNDLE_DIR/run-board.sh"

echo "===== 创建 bundle 压缩包 ====="
cd /tmp
tar czf "$TOP/test-oh-arm-bundle.tar.gz" \
  --transform='s|toybox-board-bundle/||' \
  toybox-board-bundle/
cd "$TOP"

echo ""
echo "===== 完成 ====="
echo "Bundle: $TOP/test-oh-arm-bundle.tar.gz"
echo "大小:   $(du -h test-oh-arm-bundle.tar.gz | cut -f1)"
echo "内容:"
echo "  bin/            - 预编译 ARM 二进制 (23 个)"
echo "  test-oh/        - .test 测试文件"
echo "  scripts/        - runtest.sh + config.h"
echo "  run-board.sh    - Windows 端运行脚本"
echo ""
echo "使用步骤:"
echo "  1. scp test-oh-arm-bundle.tar.gz user@windows-machine:~/"
echo "  2. Windows 上解压 (tar xzf test-oh-arm-bundle.tar.gz)"
echo "  3. cd test-oh-arm-bundle"
echo "  4. export HDC=/path/to/hdc.exe"
echo "  5. ./run-board.sh          # 跑全部"
echo "  6. ./run-board.sh ls grep  # 跑指定"
