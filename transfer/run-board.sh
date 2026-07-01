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
#   hdc file send toybox /data/toybox-test/toybox   # 先推送待测二进制
#   ./run-board.sh              # 跑全部 21 个测试
#   ./run-board.sh ls grep ps   # 跑指定命令
#
# 环境变量:
#   HDC          hdc 可执行文件路径 (默认 hdc)
#   DEBUG=1      显示详细执行过程

TOP="$(cd "$(dirname "$0")" && pwd)"
TEST_OH_DIR="$TOP/test-oh"
SCRIPT_DIR="$TOP/scripts"
BOARD_DIR=/data/toybox-test
# Git Bash (MSYS2) 会自动将 /data/… 转换为 Windows 路径传给 hdc.exe，
# 导致路径被截断。双斜杠前缀 //data 让 MSYS2 当作 UNC 路径不转换，
# 而 OHOS/Linux 会将 // 折叠为 /，板端行为不变。
BOARD_DIR_DISPLAY="$BOARD_DIR"
case "$(uname -s)" in MINGW*|MSYS*) BOARD_DIR="//data/toybox-test" ;; esac

# 可配置: hdc 路径
HDC="${HDC:-hdc}"

# 报告输出目录
REPORT_DIR="$TOP/_reports"
mkdir -p "$REPORT_DIR"
REPORT_LOG="$REPORT_DIR/report-$(date +%Y%m%d-%H%M%S).log"

# 所有输出同时写入日志文件
exec > >(tee -a "$REPORT_LOG") 2>&1

echo "=========================================="
echo "  OHOS Toybox 板端测试运行器"
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
  echo "  3. 如需启动: hdc start"
  exit 1
fi
echo "主板连接正常"

# hdc_cleanup: 清理板端测试内容，保留推送的 toybox 二进制
hdc_cleanup() {
  # 保留推送版 toybox 及测试数据 files/
  "$HDC" shell "cd $BOARD_DIR && ls -a 2>/dev/null | while read f; do case \"\$f\" in .|..|toybox|files) continue ;; esac; rm -rf \"\$f\"; done" 2>/dev/null
}

# 固定使用推送版 toybox（需提前 hdc file send 到 BOARD_DIR）
TOYBOX_CMD="$BOARD_DIR/toybox"
echo "toybox 路径: $BOARD_DIR_DISPLAY/toybox (推送版本)"

# 清理板端工作目录（保留推送版 toybox），再确保目录存在
hdc_cleanup
"$HDC" shell "mkdir -p $BOARD_DIR" 2>/dev/null
# 测试数据文件按需同步（只有用到 $FILES 的测试才推送）
# 使用 base64 通过 shell 通道传输，避免 hdc file send 在 Windows 上的路径问题
FILES_SRC="$TOP/../tests/files"
export FILES="$BOARD_DIR/files"

# 导出 TOYBOX 路径（test 文件可用 \$TOYBOX 调用 toybox 下的其他子命令）
export TOYBOX="$TOYBOX_CMD"

# 确定测试文件列表（指定参数只跑指定项，否则跑全部）
# 参数可以是命令名（cat, ls）或 glob 模式（[a-c]*），自动解析为 test-oh/*.test
if [ $# -eq 0 ]; then
  set -- "$TEST_OH_DIR"/*.test
else
  RESOLVED=()
  for arg in "$@"; do
    # 如果 arg 含通配符，在 test-oh/ 下展开
    if [[ "$arg" == *[*?\[]* ]]; then
      for tf in "$TEST_OH_DIR"/${arg}.test; do
        [ -f "$tf" ] && RESOLVED+=("$tf")
      done
    else
      # 否则当作命令名，去掉可能携带的 .test 后缀
      cmd="${arg%.test}"
      cmd="${cmd%.*}"
      tf="$TEST_OH_DIR/$cmd.test"
      [ -f "$tf" ] && RESOLVED+=("$tf") || echo "警告: 未找到测试 '$cmd' (通配符请加引号如 '[a-c]*')" >&2
    fi
  done
  set -- "${RESOLVED[@]}"
  [ $# -eq 0 ] && echo "错误: 没有匹配的测试文件" && exit 1
fi

# 检查主板上的 toybox 是否支持各命令（简单试跑 --help）
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

  # 同步测试创建的文件和目录到板端（递归，支持子目录）
  # Windows 上 echo > file 可能产生 CRLF，板端 cut -s 会对被抑制行
  # 也输出 \r\n，导致对比出现空行。对文本文件发送前 strip \r。
  # 二进制文件（含 NUL 字节的如 data.bz2、binary.txt）原样发送。
  # 注意：hdc_cleanup 只在测试文件间运行，同一文件内的多个 testing()
  # 调用共享板端工作目录，必须在同步前处理文件↔目录类型冲突。
  while IFS= read -r -d '' f; do
    f="${f#./}"
    if [ -d "$f" ]; then
      "$HDC" shell "rm -f $BOARD_DIR/$f 2>/dev/null; mkdir -p $BOARD_DIR/$f" 2>/dev/null
    elif [ -f "$f" ]; then
      "$HDC" shell "rm -rf $BOARD_DIR/$f 2>/dev/null" 2>/dev/null
      b64=
      if od -A n -t x1 "$f" 2>/dev/null | grep -q ' 00'; then
        b64=$(base64 -w0 "$f" 2>/dev/null) || continue
      else
        b64=$(tr -d '\r' < "$f" | base64 -w0 2>/dev/null) || continue
      fi
      "$HDC" shell "printf '%s' '$b64' | $TOYBOX_CMD base64 -d > $BOARD_DIR/$f" 2>/dev/null
      # 同步文件权限（mode 000 etc.）
      _mode=$(stat -c "%a" "$f" 2>/dev/null) && [ -n "$_mode" ] &&
        "$HDC" shell "chmod $_mode $BOARD_DIR/$f" 2>/dev/null
    fi
  done < <(find . -mindepth 1 -print0)

  # 推送 stdin 文件（如有）
  if [ -n "$5" ]; then
    # 用 printf '%b' 解释 \n 等转义序列，匹配上游 echo -ne 行为
    printf '%b' "$5" > "$TESTDIR/stdin"
    local b64
    b64=$(base64 -w0 "$TESTDIR/stdin" 2>/dev/null)
    "$HDC" shell "printf '%s' '$b64' | $TOYBOX_CMD base64 -d > $BOARD_DIR/stdin" 2>/dev/null
  fi

  # 直接在板端执行命令（保留末尾换行，$() 会吃掉，所以重定向到临时文件）
  # 非空 stdin → 板端文件重定向；空 stdin → /dev/null 确保 stdin 立即 EOF 不卡死
  if [ -n "$5" ]; then
    # 用 { } 包裹，确保 stdin 重定向作用于整个复合命令（而非 && 后的最后一个子命令）
    "$HDC" shell "cd $BOARD_DIR && { $REMOTE_CMD; } < $BOARD_DIR/stdin" > "$TESTDIR/actual.raw" 2>/dev/null
  else
    "$HDC" shell "cd $BOARD_DIR && { $REMOTE_CMD; } < /dev/null" > "$TESTDIR/actual.raw" 2>/dev/null
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

  [ -n "$DIFF" ] && ! verbose_has all && { rm -f input; rm -rf "$TESTDIR"; exit 1; }
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

  # 按需同步测试数据（内联执行）
  # 每个命令只同步它实际需要的文件，定义文件依赖映射：
  #   blkid/fstype → blkid/    bzcat → blkid/ + bzcat/
  #   file → 根目录 + tar/ + utf8/ + zip/ + elf/
  #   tar  → tar/              wc   → utf8/
  case "$CMDNAME" in
    blkid|fstype) SYNC_ITEMS="blkid" ;;
    bzcat)        SYNC_ITEMS="blkid bzcat" ;;
    file)         SYNC_ITEMS=". tar utf8 zip elf" ;;
    tar)          SYNC_ITEMS="tar" ;;
    wc)           SYNC_ITEMS="utf8" ;;
    *)            SYNC_ITEMS="" ;;
  esac
  if [ -n "$SYNC_ITEMS" ]; then
    echo "同步测试数据到板端 $FILES ..."
    # 重建干净的文件目录，避免之前残留的 同名目录/文件 冲突（如 java.class）
    "$HDC" shell "rm -rf ${BOARD_DIR}/files && mkdir -p ${BOARD_DIR}/files" 2>/dev/null
    for _item in $SYNC_ITEMS; do
      if [ "$_item" = "." ]; then
        _src_dir="$FILES_SRC"
        _rel_prefix=""
      else
        _src_dir="$FILES_SRC/$_item"
        _rel_prefix="$_item/"
      fi
      [ -d "$_src_dir" ] || continue
      find "$_src_dir" -type f -print0 | while IFS= read -r -d '' _f; do
        _rel="${_rel_prefix}${_f#$_src_dir/}"
        # base64 编码后分块写入板端，避免大文件时 printf 命令行超长
        _b64=$(base64 -w0 "$_f" 2>/dev/null) || { echo "  [FAIL] base64: $_rel"; continue; }
        _total=${#_b64}
        _off=0
        _first=true
        while [ $_off -lt $_total ]; do
          _chunk="${_b64:$_off:8000}"
          if $_first; then
            "$HDC" shell "printf '%s' '$_chunk' > ${BOARD_DIR}/files/_tmp.b64" 2>/dev/null
            _first=false
          else
            "$HDC" shell "printf '%s' '$_chunk' >> ${BOARD_DIR}/files/_tmp.b64" 2>/dev/null
          fi
          _off=$((_off + 8000))
        done
        # 创建父目录（仅当路径含 /）
        case "$_rel" in
          */*) "$HDC" shell "mkdir -p ${BOARD_DIR}/files/${_rel%/*}" 2>/dev/null ;;
        esac
        if "$HDC" shell "$TOYBOX_CMD base64 -d < ${BOARD_DIR}/files/_tmp.b64 > ${BOARD_DIR}/files/$_rel && rm ${BOARD_DIR}/files/_tmp.b64" 2>/dev/null; then
          echo "  [OK] $_rel"
        else
          echo "  [FAIL] $_rel"
        fi
      done
    done
    echo "同步完成"
  fi

  C="$TOYBOX_CMD $CMDNAME"
  # 在干净的工作目录中运行测试，避免污染 $TOP
  # 测试创建的文件/目录会在此目录，testing() 只同步此目录内容
  WORKDIR="$TOP/_test/${CMDNAME}_work"
  rm -rf "$WORKDIR"
  mkdir -p "$WORKDIR"
  (
    cd "$WORKDIR"
    # 重定向常用文件操作命令：本地+板端同步执行
    rm() { command rm -rf "$@"; "$HDC" shell "rm -rf $BOARD_DIR/$*" 2>/dev/null; }
    mkdir() { command mkdir -p "$@"; "$HDC" shell "mkdir -p $BOARD_DIR/$*" 2>/dev/null; }
    touch() { command touch "$@"; "$HDC" shell "touch $BOARD_DIR/$*" 2>/dev/null; }
    chmod() {
      local _file="${@: -1}" _rest="${@:1:$#-1}"
      command chmod "$@"
      "$HDC" shell "chmod $_rest $BOARD_DIR/$_file" 2>/dev/null || true
    }
    # 无论 exit 还是正常结束，都写 FAILCOUNT（trap 保证 subshell 退出时执行）
    trap "echo \$FAILCOUNT > '$TOP/_test/${CMDNAME}_continue'" EXIT
    source "$TEST_OH_DIR/$CMDNAME.test"
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

# 生成 HTML 报告
REPORT_HTML="$REPORT_DIR/report-$(date +%Y%m%d-%H%M%S).html"
"$TOP/gen-report.sh" < "$REPORT_LOG" > "$REPORT_HTML" 2>/dev/null && \
  echo "报告已生成: $REPORT_HTML" || \
  echo "报告生成失败"

# 清理日志中可能存在的敏感信息
chmod 644 "$REPORT_LOG" "$REPORT_HTML" 2>/dev/null

exit $FAILCOUNT
