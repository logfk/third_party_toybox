#!/bin/bash

# test-oh/run-on-board.sh - 交叉编译 OHOS 测试并在主板上运行
# 原理: .test 文件的 bash 逻辑在宿主机执行（echo >input 等），
#       仅命令执行通过 hdc 重定向到主板
# 用法: test-oh/run-on-board.sh [test_name...]

TOP="$(cd "$(dirname "$0")/.." && pwd)"
HDC=/srv/workspace/openharmony_master_default_20260624175729_huawei_5a33ef946/code/prebuilts/ohos-sdk/linux/26/toolchains/hdc
BOARD_DIR=/data/toybox-test
BIN_DIR="$TOP/generated/test-oh-arm"

# 工具链
TOOLCHAIN=/srv/workspace/openharmony_master_default_20260624175729_huawei_5a33ef946/code/prebuilts/clang/ohos/linux-x86_64/llvm/bin
SYSROOT=/srv/workspace/openharmony_master_default_20260624175729_huawei_5a33ef946/code/prebuilts/ohos-sdk/linux/26/native/sysroot

export PATH=$TOOLCHAIN:$PATH
export CC=clang
export CROSS_COMPILE=armv7-unknown-linux-ohos-
export CFLAGS="-DTOYBOX_OH_ADAPT --sysroot=$SYSROOT -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types"
export LDFLAGS="--sysroot=$SYSROOT -L$SYSROOT/usr/lib/arm-linux-ohos"

cd "$TOP"
[ ! -f .config ] && make defconfig
sed -i '/CONFIG_\(LOGIN\|LOGIN_SHADOW\|UPTIME\|W\|PING\|NETCAT\|WHO\)=y/s/=y/# & is not set/' .config

# 检查连接
$HDC list targets 2>&1 | grep -q "." || { echo "错误: 未检测到主板"; exit 1; }

echo "=== 清理主板旧文件 ==="
$HDC shell "rm -rf $BOARD_DIR && mkdir -p $BOARD_DIR"

[ $# -eq 0 ] && set -- "$TOP"/test-oh/*.test

for testfile in "$@"; do
  CMDNAME="$(basename "${testfile%.test}")"
  BOARD_CMD="$BOARD_DIR/$CMDNAME"

  echo ""
  echo "=========================================="
  echo "  测试: $CMDNAME"
  echo "=========================================="

  # 1. 交叉编译
  echo "  [编译] $CMDNAME ..."
  mkdir -p "$BIN_DIR"
  PREFIX="$BIN_DIR/" CFLAGS="$CFLAGS" scripts/single.sh "$CMDNAME" 2>/dev/null || {
    echo "  [跳过] 编译失败"; continue
  }

  # 2. 推送到主板
  echo "  [推送] $CMDNAME"
  $HDC file send "$BIN_DIR/$CMDNAME" "$BOARD_CMD" >/dev/null 2>&1
  $HDC shell "chmod +x $BOARD_CMD"

  # 3. 设置测试环境
  export TOPDIR="$TOP"
  export TESTDIR="$BIN_DIR/${CMDNAME}_test"
  export OHOS_TEST=1
  export SHOWSKIP=SKIP
  rm -rf "$TESTDIR"

  # 收集 OPTIONFLAGS
  [ -f "$TOP/generated/config.h" ] &&
    export OPTIONFLAGS=:$(sed -n 's/^#define CFG_\(.*\) 1$/\1/p' "$TOP/generated/config.h" | tr '\n' :)

  # 加载测试框架
  source "$TOP/scripts/runtest.sh"

  # 重写 testing 函数：宿主机处理 IO，通过 hdc 在主板执行命令
  testing() {
    wrong_args "$@"
    [ -z "$1" ] && NAME="$2" || NAME="$1"
    [ "${NAME#$CMDNAME }" == "$NAME" ] && NAME="$CMDNAME $1"

    [ -n "$DEBUG" ] && set -x

    if [ "$SKIP" -gt 0 ]; then
      verbose_has quiet || printf "%s\n" "$SHOWSKIP: $NAME"
      ((--SKIP)); return 0
    fi

    # 期望结果
    echo -ne "$3" > "$TESTDIR/expected"

    # 输入文件（由 .test 的 bash 命令在宿主机创建）
    [ ! -f input ] && rm -f input
    [ -n "$4" ] && echo -ne "$4" > input

    # 同步当前目录所有文件到主板（覆盖 input 文件）
    for f in * .*; do
      [ "$f" = "." ] || [ "$f" = ".." ] && continue
      [ -f "$f" ] && $HDC file send "$f" "$BOARD_DIR/$f" >/dev/null 2>&1
    done

    # 推送 stdin
    if [ -n "$5" ]; then
      printf '%s' "$5" | $HDC shell "cat > $BOARD_DIR/stdin" 2>/dev/null
    fi

    # 构建远程命令
    REMOTE_CMD="$2"
    REMOTE_CMD="${REMOTE_CMD//\$C/$BOARD_CMD}"

    # 在主板执行（在 BOARD_DIR 下，可直接访问文件名）
    if [ -n "$5" ]; then
      ACTUAL=$($HDC shell "cd $BOARD_DIR && $REMOTE_CMD < stdin" 2>/dev/null)
    else
      ACTUAL=$($HDC shell "cd $BOARD_DIR && $REMOTE_CMD" 2>/dev/null)
    fi
    RETVAL=$?

    echo -ne "$ACTUAL" > "$TESTDIR/actual"

    # 段错误检测
    [ $RETVAL -gt 128 ] && echo "exited with signal (or returned $RETVAL)" >> "$TESTDIR/actual"

    DIFF="$(cd "$TESTDIR"; diff -au expected actual 2>&1)"
    [ -z "$DIFF" ] && do_pass || { VERBOSE=all do_fail; }
    if ! verbose_has quiet && { [ -n "$DIFF" ] || verbose_has spam; }; then
      [ -n "$4" ] && printf "%s\n" "echo -ne \"$4\" > input"
      printf "%s\n" "echo -ne '$5' | $REMOTE_CMD"
      [ -n "$DIFF" ] && printf "%s\n" "$DIFF"
    fi
    [ -n "$DIFF" ] && ! verbose_has all && exit 1
    rm -f input "$TESTDIR/../expected" "$TESTDIR/../actual"
    [ -n "$DEBUG" ] && set +x
    return 0
  }

  # 4. 执行测试
  C="$BOARD_CMD"
  mkdir -p "$TESTDIR/testdir"
  cd "$TESTDIR/testdir" || exit 1

  (
    . "$TOP/test-oh/$CMDNAME.test"
    echo "$FAILCOUNT" > "$TESTDIR/continue"
  )

  cd "$TESTDIR"
  [ -e continue ] && FAILCOUNT=$(($(cat continue) + FAILCOUNT)) || exit 1

  # 清理主板
  $HDC shell "rm -rf $BOARD_DIR/*" 2>/dev/null
  echo ""
done

$HDC shell "rm -rf $BOARD_DIR" 2>/dev/null

echo "=========================================="
[ $FAILCOUNT -eq 0 ] && echo "  全部通过!" || echo "  失败: $FAILCOUNT"
echo "=========================================="
exit $FAILCOUNT
