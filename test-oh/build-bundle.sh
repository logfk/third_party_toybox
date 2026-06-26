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

echo "===== 清理主板旧文件 ====="
"$HDC" shell "rm -rf $BOARD_DIR && mkdir -p $BOARD_DIR"

# 推送全部预编译二进制
echo "===== 推送二进制到主板 ====="
BIN_COUNT=0
for f in "$BIN_DIR"/*; do
  [ -f "$f" ] || continue
  CMDNAME="$(basename "$f")"
  echo "  [推送] $CMDNAME"
  "$HDC" file send "$f" "$BOARD_DIR/$CMDNAME" >/dev/null 2>&1
  "$HDC" shell "chmod +x $BOARD_DIR/$CMDNAME"
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
  mkdir -p "$TESTDIR/testdir"
  cd "$TESTDIR/testdir" || return 1

  # 写入期望结果
  echo -ne "$3" > "$TESTDIR/expected"

  # 写入 input 文件
  [ -n "$4" ] && echo -ne "$4" > input

  # 同步本地文件到板端
  for f in * .*; do
    [ "$f" = "." ] || [ "$f" = ".." ] && continue
    [ -f "$f" ] && "$HDC" file send "$f" "$BOARD_DIR/$f" >/dev/null 2>&1
  done

  # 推送 stdin
  if [ -n "$5" ]; then
    printf '%s' "$5" | "$HDC" shell "cat > $BOARD_DIR/stdin" 2>/dev/null
  fi

  # 构建远程命令：将 $C 替换为板端路径
  REMOTE_CMD="$2"
  REMOTE_CMD="${REMOTE_CMD//\$C/$BOARD_DIR/$CMDNAME}"

  # 在板端执行
  if [ -n "$5" ]; then
    ACTUAL=$("$HDC" shell "cd $BOARD_DIR && $REMOTE_CMD < stdin" 2>/dev/null)
  else
    ACTUAL=$("$HDC" shell "cd $BOARD_DIR && $REMOTE_CMD" 2>/dev/null)
  fi
  RETVAL=$?

  echo -ne "$ACTUAL" > "$TESTDIR/actual"
  [ $RETVAL -gt 128 ] && echo "exited with signal (or returned $RETVAL)" >> "$TESTDIR/actual"

  # 比对
  DIFF="$(cd "$TESTDIR"; diff -au expected actual 2>&1)"
  [ -z "$DIFF" ] && do_pass || { VERBOSE=all do_fail; }

  if ! verbose_has quiet && { [ -n "$DIFF" ] || verbose_has spam; }; then
    [ -n "$4" ] && printf "%s\n" "echo -ne \"$4\" > input"
    printf "%s\n" "echo -ne '$5' | $REMOTE_CMD"
    [ -n "$DIFF" ] && printf "%s\n" "$DIFF"
  fi

  [ -n "$DIFF" ] && ! verbose_has all && { cd "$TOP"; return 1; }
  rm -f input "$TESTDIR/../expected" "$TESTDIR/../actual"
  rm -rf "$TESTDIR"
  [ -n "$DEBUG" ] && set +x
  return 0
}

# ====== 遍历执行测试 ======
for testfile in "$@"; do
  CMDNAME="$(basename "${testfile%.test}")"
  BOARD_CMD="$BOARD_DIR/$CMDNAME"
  echo ""
  echo "=========================================="
  echo "  测试: $CMDNAME"
  echo "=========================================="

  # 检查二进制是否存在
  "$HDC" shell "[ -f $BOARD_DIR/$CMDNAME ]" 2>/dev/null || {
    echo "  [跳过] 二进制 $CMDNAME 不在板端"
    continue
  }

  # 在顶层 TOP 目录下加载 .test
  C="$BOARD_DIR/$CMDNAME"
  (
    cd "$TOP"
    source "$TEST_OH_DIR/$CMDNAME.test"
    echo "$FAILCOUNT" > "$TOP/_test/${CMDNAME}_continue"
  ) || true

  if [ -f "$TOP/_test/${CMDNAME}_continue" ]; then
    FAILCOUNT=$(($(cat "$TOP/_test/${CMDNAME}_continue") + FAILCOUNT))
    rm -f "$TOP/_test/${CMDNAME}_continue"
  fi

  # 清理板端
  "$HDC" shell "rm -rf $BOARD_DIR/*" 2>/dev/null
done

# 恢复二进制（清理时删掉了所有，重新推送一次以便后续测试）
for f in "$BIN_DIR"/*; do
  [ -f "$f" ] || continue
  "$HDC" file send "$f" "$BOARD_DIR/$(basename "$f")" >/dev/null 2>&1
  "$HDC" shell "chmod +x $BOARD_DIR/$(basename "$f")" 2>/dev/null
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
