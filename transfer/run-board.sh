#!/bin/bash
# run-board.sh - 在 Windows (Git Bash) 上通过 hdc 在主板运行 OHOS toybox 测试
#
# 架构：测试脚本（setup + 被测命令）整体在板端执行，Windows 端只负责
#       推送测试包、收集输出、生成报告。这样 setup 与被测命令共享同一
#       环境，消除“本地 setup + 板端执行”导致的状态/路径/权限错配。
#
# 前提:
#   1. hdc 能连到主板 (hdc list targets 能看到设备)
#   2. 已推送待测 toybox 到 /data/toybox-test/toybox
#      hdc file send toybox //data/toybox-test/toybox
#   3. Windows 有 Git Bash (需要 bash)
#
# 用法:
#   ./run-board.sh              # 跑全部测试
#   ./run-board.sh ls grep ps   # 跑指定命令
#   ./run-board.sh '[a-c]*'     # 通配符
#
# 环境变量:
#   HDC          hdc 可执行文件路径 (默认 hdc)
#   NO_SYNC=1    跳过测试包同步（已推送过，加速重复运行）
#   DEBUG=1      显示详细执行过程

TOP="$(cd "$(dirname "$0")" && pwd)"
TEST_OH_DIR="$TOP/test-oh"
SCRIPT_DIR="$TOP/scripts"
FILES_SRC="$TOP/../tests/files"

# 板端路径。Git Bash (MSYS2) 会把 /data/… 当 Windows 路径转换给 hdc.exe，
# 双斜杠 //data 让 MSYS2 视作 UNC 不转换，板端 // 折叠为 /。
REMOTE_ROOT=/data/toybox-test
REMOTE_ROOT_ARG="$REMOTE_ROOT"
case "$(uname -s)" in MINGW*|MSYS*) REMOTE_ROOT_ARG="//data/toybox-test" ;; esac

HDC="${HDC:-hdc}"

# 报告输出目录
REPORT_DIR="$TOP/_reports"
mkdir -p "$REPORT_DIR"
REPORT_LOG="$REPORT_DIR/report-$(date +%Y%m%d-%H%M%S).log"

# 所有输出同时写入日志（供 gen-report.sh 解析）
exec > >(tee -a "$REPORT_LOG") 2>&1

echo "=========================================="
echo "  OHOS Toybox 板端测试运行器（板端执行模式）"
echo "  hdc:      $HDC"
echo "  测试目录: $TEST_OH_DIR"
echo "  日志文件: $REPORT_LOG"
echo "=========================================="

# 检查 hdc 连接
if ! "$HDC" list targets 2>&1 | grep -q "."; then
  echo "错误: hdc 未检测到主板"
  echo "请检查:"
  echo "  1. USB 是否连接"
  echo "  2. 'hdc list targets' 是否有输出"
  exit 1
fi
echo "主板连接正常"

# 固定使用推送版 toybox
TOYBOX_CMD="$REMOTE_ROOT_ARG/toybox"
if ! "$HDC" shell "test -f $REMOTE_ROOT_ARG/toybox && echo ok" 2>/dev/null | grep -q ok; then
  echo "警告: 未找到 $REMOTE_ROOT/toybox，请先推送："
  echo "  hdc file send toybox $REMOTE_ROOT_ARG/toybox"
  echo "  hdc shell \"chmod +x $REMOTE_ROOT_ARG/toybox\""
fi
echo "toybox 路径: $REMOTE_ROOT/toybox (推送版本)"

# ====== 确定测试文件列表 ======
if [ $# -eq 0 ]; then
  set -- "$TEST_OH_DIR"/*.test
else
  RESOLVED=()
  for arg in "$@"; do
    if [[ "$arg" == *[*?\[]* ]]; then
      for tf in "$TEST_OH_DIR"/${arg}.test; do
        [ -f "$tf" ] && RESOLVED+=("$tf")
      done
    else
      cmd="${arg%.test}"
      tf="$TEST_OH_DIR/$cmd.test"
      [ -f "$tf" ] && RESOLVED+=("$tf") || echo "警告: 未找到测试 '$cmd'" >&2
    fi
  done
  set -- "${RESOLVED[@]}"
  [ $# -eq 0 ] && { echo "错误: 没有匹配的测试文件"; exit 1; }
fi

# ====== 同步测试包到板端 ======
# 推送：testing.sh(框架) + board-run.sh(入口) + test-oh/*.test + tests/files/
sync_bundle() {
  echo ""
  echo "===== 同步测试包到板端 ====="

  "$HDC" shell "rm -rf $REMOTE_ROOT_ARG/test-oh $REMOTE_ROOT_ARG/files && mkdir -p $REMOTE_ROOT_ARG/test-oh $REMOTE_ROOT_ARG/files" 2>/dev/null

  # 1) 框架 + 入口（小文本文件，base64 单次）
  for f in "$SCRIPT_DIR/runtest.sh" "$SCRIPT_DIR/board-run.sh"; do
    name="$(basename "$f")"
    # 板端 testing.sh 即 runtest.sh（test 文件首行 [ -f testing.sh ] && . testing.sh）
    [ "$name" = "runtest.sh" ] && name="testing.sh"
    b64=$(base64 -w0 "$f" 2>/dev/null)
    "$HDC" shell "printf '%s' '$b64' | $TOYBOX_CMD base64 -d > $REMOTE_ROOT_ARG/$name" 2>/dev/null \
      && echo "  [OK] $name" || echo "  [FAIL] $name"
  done

  # 2) test-oh/*.test
  local ok=0 fail=0
  for tf in "$TEST_OH_DIR"/*.test; do
    name="$(basename "$tf")"
    b64=$(base64 -w0 "$tf" 2>/dev/null) || { echo "  [FAIL] $name"; ((fail++)); continue; }
    "$HDC" shell "printf '%s' '$b64' | $TOYBOX_CMD base64 -d > $REMOTE_ROOT_ARG/test-oh/$name" 2>/dev/null \
      && { ((ok++)); } || { echo "  [FAIL] $name"; ((fail++)); }
  done
  echo "  test-oh: $ok 个推送成功${fail:+，$fail 个失败}"

  # 3) tests/files/（部分测试依赖：file/wc/blkid/tar/bc/awk/bzcat ...）
  if [ -d "$FILES_SRC" ]; then
    echo "  同步 files/ ..."
    sync_files_dir "$FILES_SRC" ""
  else
    echo "  跳过 files/（未找到 $FILES_SRC）"
  fi
}

# 递归同步 files/ 目录：base64 分块避免命令行超长
sync_files_dir() {
  local src="$1" relprefix="$2"
  find "$src" -type f -print0 | while IFS= read -r -d '' lf; do
    local rel="${relprefix}${lf#$src/}"
    # 创建父目录
    case "$rel" in
      */*) "$HDC" shell "mkdir -p $REMOTE_ROOT_ARG/files/${rel%/*}" 2>/dev/null ;;
    esac
    local b64 total off chunk first=true
    b64=$(base64 -w0 "$lf" 2>/dev/null) || { echo "    [FAIL] $rel"; continue; }
    total=${#b64}; off=0
    while [ $off -lt $total ]; do
      chunk="${b64:$off:8000}"
      if $first; then
        "$HDC" shell "printf '%s' '$chunk' > $REMOTE_ROOT_ARG/files/_tmp.b64" 2>/dev/null
        first=false
      else
        "$HDC" shell "printf '%s' '$chunk' >> $REMOTE_ROOT_ARG/files/_tmp.b64" 2>/dev/null
      fi
      off=$((off + 8000))
    done
    "$HDC" shell "$TOYBOX_CMD base64 -d < $REMOTE_ROOT_ARG/files/_tmp.b64 > $REMOTE_ROOT_ARG/files/$rel && rm -f $REMOTE_ROOT_ARG/files/_tmp.b64" 2>/dev/null \
      && echo "    [OK] $rel" || echo "    [FAIL] $rel"
  done
}

if [ -z "$NO_SYNC" ]; then
  sync_bundle
else
  echo "NO_SYNC=1，跳过测试包同步"
fi

# ====== 检查主板命令支持 ======
echo ""
echo "===== 检查主板命令支持 ====="
MISSING=0
for testfile in "$@"; do
  CMDNAME="$(basename "${testfile%.test}")"
  if "$HDC" shell "$TOYBOX_CMD $CMDNAME --help" > /dev/null 2>&1; then
    echo "  [OK] $CMDNAME"
  else
    echo "  [--] $CMDNAME (不支持)"
    ((MISSING++))
  fi
done
[ $MISSING -gt 0 ] && echo "  $MISSING 个命令不被主板支持，对应测试将被跳过"

# ====== 在板端逐个执行测试 ======
TOTAL_FAIL=0
TMP_OUT="$REPORT_DIR/.last-run.out"
for testfile in "$@"; do
  CMDNAME="$(basename "${testfile%.test}")"

  echo ""
  echo "=========================================="
  echo "  测试: $CMDNAME"
  echo "=========================================="

  # 板端整体执行：setup 与被测命令同环境
  #   - board-run.sh 内部 cd 到独立 workdir，互不污染
  #   - VERBOSE=all 使首条失败后继续跑完该命令的所有用例
  #   - tr -d '\r' 去掉 hdc 在 Windows 上可能引入的 CR
  # 输出经外层 exec 的 tee 自动写入 REPORT_LOG；这里再落临时文件便于计数
  "$HDC" shell \
    "cd $REMOTE_ROOT_ARG && CMDNAME=$CMDNAME OHOS_TEST=1 TOYBOX=$TOYBOX_CMD FILES=$REMOTE_ROOT_ARG/files VERBOSE=all FAILCOUNT=0 sh $REMOTE_ROOT_ARG/board-run.sh $CMDNAME" \
    2>&1 | tr -d '\r' | tee "$TMP_OUT"
  fc=$(grep -c '^FAIL:' "$TMP_OUT" 2>/dev/null || true)
  TOTAL_FAIL=$((TOTAL_FAIL + ${fc:-0}))
done
rm -f "$TMP_OUT"

echo ""
echo "=========================================="
[ "$TOTAL_FAIL" -eq 0 ] && echo "  全部通过!" || echo "  失败: $TOTAL_FAIL"
echo "=========================================="

# 生成 HTML 报告（gen-report.sh 解析本日志）
REPORT_HTML="$REPORT_DIR/report-$(date +%Y%m%d-%H%M%S).html"
"$TOP/gen-report.sh" < "$REPORT_LOG" > "$REPORT_HTML" 2>/dev/null \
  && echo "报告已生成: $REPORT_HTML" \
  || echo "报告生成失败"

chmod 644 "$REPORT_LOG" "$REPORT_HTML" 2>/dev/null
exit $TOTAL_FAIL
