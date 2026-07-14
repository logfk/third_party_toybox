#!/bin/bash
# gen-index.sh - Generate main index page listing all test runs
# Usage: ./gen-index.sh [reports_dir]

REPORTS_DIR="${1:-$(cd "$(dirname "$0")" && pwd)/_reports}"
mkdir -p "$REPORTS_DIR"
INDEX_FILE="$REPORTS_DIR/index.html"

# Collect run data
RUNS=()
for dir in "$REPORTS_DIR"/run-*/; do
    [ -d "$dir" ] || continue
    [ -f "$dir/stats.txt" ] || continue
    RUNS+=("$dir")
done

# Sort runs by name (newest first)
if [ ${#RUNS[@]} -gt 0 ]; then
    IFS=$'\n' RUNS=($(sort -r <<<"${RUNS[*]}")); unset IFS
fi

# ---- Generate HTML ----
cat > "$INDEX_FILE" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OHOS Toybox Test Reports</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;background:#0f0f23;color:#e0e0e0;line-height:1.6}
.container{max-width:960px;margin:0 auto;padding:20px}
@media(max-width:600px){.container{padding:10px}}
header{text-align:center;padding:30px 0;border-bottom:1px solid #2a2a4e;margin-bottom:30px}
header h1{font-size:1.8em;color:#e8e8ff;margin-bottom:6px;font-weight:700}
header .sub{color:#888;font-size:0.9em}
.section{background:#161638;border-radius:12px;padding:24px;margin-bottom:20px}
.section-title{font-size:1.15em;color:#e8e8ff;margin-bottom:14px;padding-bottom:10px;border-bottom:1px solid #2a2a4e}
.run-list{display:flex;flex-direction:column;gap:12px}
.run-card{background:#1a1a3e;border-radius:10px;padding:16px 20px;display:flex;align-items:center;gap:16px;border:1px solid #2a2a4e;text-decoration:none;color:inherit;transition:background .2s,transform .1s}
.run-card:hover{background:#22224e;transform:translateY(-2px);border-color:#4e4e8e}
.run-card .run-time{font-weight:600;color:#e8e8ff;font-size:1em;white-space:nowrap;min-width:140px}
.run-card .run-stats{display:flex;gap:8px;flex-wrap:wrap;flex:1}
.run-card .stat-badge{display:inline-flex;align-items:center;gap:4px;padding:2px 8px;border-radius:3px;font-size:0.75em;font-weight:600}
.run-card .stat-badge.pass{background:#0d2b1a;color:#4caf50;border:1px solid #1a5a2a}
.run-card .stat-badge.fail{background:#2b0d0d;color:#f44336;border:1px solid #5a1a1a}
.run-card .stat-badge.skip{background:#2b2b0d;color:#ff9800;border:1px solid #5a5a1a}
.run-card .stat-badge.total{background:#1e1e4a;color:#aaa;border:1px solid #3a3a5e}
.run-card .run-link{color:#4e4e8e;font-size:1.2em;white-space:nowrap}
.empty-msg{text-align:center;color:#666;padding:40px;font-size:1.1em}
footer{text-align:center;padding:20px;color:#555;font-size:0.85em}
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>OHOS Toybox Test Reports</h1>
    <div class="sub">All Test Runs</div>
  </header>
  <div class="section">
    <h2 class="section-title">测试记录</h2>
HTMLHEAD

if [ ${#RUNS[@]} -eq 0 ]; then
    echo '    <div class="empty-msg">暂无测试记录</div>' >> "$INDEX_FILE"
else
    echo '    <div class="run-list">' >> "$INDEX_FILE"
    for dir in "${RUNS[@]}"; do
        RUN_NAME="$(basename "$dir")"
        # Parse timestamp from folder name: run-YYYYMMDD-HHMMSS
        TS="${RUN_NAME#run-}"
        FORMATTED_TS="${TS:0:4}-${TS:4:2}-${TS:6:2} ${TS:9:2}:${TS:11:2}:${TS:13:2}"
        # Read stats: total pass fail skip
        read -r RT RF RRK RRS < "$dir/stats.txt"
        RT="${RT:-0}"; RF="${RF:-0}"; RRK="${RRK:-0}"; RRS="${RRS:-0}"
        FAIL_BADGE=""
        [ "$RRK" -gt 0 ] && FAIL_BADGE="<span class=\"stat-badge fail\">$RRK FAIL</span>"
        SKIP_BADGE=""
        [ "$RRS" -gt 0 ] && SKIP_BADGE="<span class=\"stat-badge skip\">$RRS SKIP</span>"
        cat >> "$INDEX_FILE" << CARD
      <a class="run-card" href="$RUN_NAME/index.html" title="查看测试详情">
        <div class="run-time">$FORMATTED_TS</div>
        <div class="run-stats">
          <span class="stat-badge total">$RT 项</span>
          <span class="stat-badge pass">$RF PASS</span>
          $FAIL_BADGE
          $SKIP_BADGE
        </div>
        <div class="run-link">&rarr;</div>
      </a>
CARD
    done
    echo '    </div>' >> "$INDEX_FILE"
fi

cat >> "$INDEX_FILE" << 'HTMLFOOT'
  </div>
  <footer>OHOS Toybox Test Report System</footer>
</div>
</body>
</html>
HTMLFOOT

echo "主页面已生成: $INDEX_FILE"
