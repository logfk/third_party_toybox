#!/bin/bash
# gen-report.sh - Parse OHOS Toybox test output and generate HTML report
# Usage: ./run-board.sh 2>&1 | ./gen-report.sh > report.html
# Compatible with Git Bash (Windows), bash 3.2+

# ---- Read all input ----
INPUT=()
while IFS= read -r line; do
    INPUT+=("$line")
done

if [ ${#INPUT[@]} -eq 0 ]; then
    echo "No input data" >&2
    exit 1
fi

# ---- Data structures ----
declare -a BOARD_OK BOARD_NO SECTIONS RESULTS RES_SECTION FAIL_CMD FAIL_DIFF
CUR_SIDX=-1
CUR_RIDX=-1
IN_BOARD=false
IN_FAIL=false

# ---- Parse ----
for ((i=0; i<${#INPUT[@]}; i++)); do
    line="${INPUT[$i]}"

    # ----- Board check -----
    if [[ "$line" == *"检查主板命令支持"* ]]; then
        IN_BOARD=true
        continue
    fi

    if $IN_BOARD; then
        if [[ "$line" =~ ^[[:space:]]*\[OK\]\ (.+)$ ]]; then
            BOARD_OK+=("${BASH_REMATCH[1]}")
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*\[--\]\ (.+)$ ]]; then
            c="${BASH_REMATCH[1]}"
            c="${c% (不支持)}"
            BOARD_NO+=("$c")
            continue
        fi
        if [ -z "$line" ] || [[ "$line" == "====="* ]]; then
            IN_BOARD=false
            [ -z "$line" ] && continue
        else
            continue
        fi
    fi

    # ----- Section / boundary markers -----
    if [[ "$line" == "==========================================" ]]; then
        IN_FAIL=false
        if ((i+1 < ${#INPUT[@]})) && [[ "${INPUT[$((i+1))]}" =~ ^[[:space:]]*测试:\ (.+)$ ]]; then
            CUR_SIDX=${#SECTIONS[@]}
            SECTIONS+=("${BASH_REMATCH[1]}")
            ((i++))
            continue
        fi
        continue
    fi

    # ----- Test results -----
    if [[ "$line" == "PASS:"* ]]; then
        IN_FAIL=false
        CUR_RIDX=${#RESULTS[@]}
        RESULTS+=("PASS:${line#PASS: }")
        RES_SECTION+=("$CUR_SIDX")
        FAIL_CMD+=("")
        FAIL_DIFF+=("")
        continue
    fi
    if [[ "$line" == "SKIP:"* ]]; then
        IN_FAIL=false
        CUR_RIDX=${#RESULTS[@]}
        RESULTS+=("SKIP:${line#SKIP: }")
        RES_SECTION+=("$CUR_SIDX")
        FAIL_CMD+=("")
        FAIL_DIFF+=("")
        continue
    fi
    if [[ "$line" == "FAIL:"* ]]; then
        IN_FAIL=true
        CUR_RIDX=${#RESULTS[@]}
        RESULTS+=("FAIL:${line#FAIL: }")
        RES_SECTION+=("$CUR_SIDX")
        FAIL_CMD+=("")
        FAIL_DIFF+=("")
        continue
    fi

    # ----- Collect FAIL details -----
    if $IN_FAIL && [ "$CUR_RIDX" -ge 0 ]; then
        if [ -z "${FAIL_CMD[$CUR_RIDX]}" ]; then
            FAIL_CMD[$CUR_RIDX]="$line"
        else
            FAIL_DIFF[$CUR_RIDX]="${FAIL_DIFF[$CUR_RIDX]}${line}"$'\n'
        fi
        continue
    fi
done

# ---- Count ----
P=0; F=0; S=0
for r in "${RESULTS[@]}"; do
    case "${r%%:*}" in
        PASS) P=$((P+1)) ;;
        FAIL) F=$((F+1)) ;;
        SKIP) S=$((S+1)) ;;
    esac
done
T=$((P+F+S))
PP=0; FP=0; SP=0
if [ "$T" -gt 0 ]; then
    PP=$((P*100/T))
    FP=$((F*100/T))
    SP=$((S*100/T))
fi

# ---- HTML helpers ----
html_esc() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# ---- Build board check HTML ----
BOARD_HTML=""
for cmd in "${BOARD_OK[@]}"; do
    BOARD_HTML="${BOARD_HTML}<li class=\"ok\"><span class=\"badge-ok\">OK</span> $(html_esc "$cmd")</li>"$'\n'
done
for cmd in "${BOARD_NO[@]}"; do
    BOARD_HTML="${BOARD_HTML}<li class=\"no\"><span class=\"badge-no\">--</span> $(html_esc "$cmd")</li>"$'\n'
done
if [ -n "$BOARD_HTML" ]; then
    BOARD_HTML="<div class=\"section\"><h2 class=\"section-title\">主板命令支持</h2><ul class=\"board-list\">${BOARD_HTML}</ul></div>"
fi

# ---- Build sections HTML ----
SECTIONS_HTML=""
for ((sid=0; sid<${#SECTIONS[@]}; sid++)); do
    sname="${SECTIONS[$sid]}"
    sec="<div class=\"section\">"$'\n'
    sec="${sec}<h2 class=\"section-title\">测试: $(html_esc "$sname")</h2>"$'\n'
    sec="${sec}<div class=\"results\">"$'\n'

    for ((rid=0; rid<${#RESULTS[@]}; rid++)); do
        [ "${RES_SECTION[$rid]}" -ne "$sid" ] && continue
        r="${RESULTS[$rid]}"
        rtype="${r%%:*}"
        rdesc="${r#*: }"
        [ "$rdesc" = "$r" ] && rdesc="${r#*:}"

        case "$rtype" in
            PASS)
                sec="${sec}<div class=\"result pass\"><span class=\"badge badge-pass\">PASS</span><span class=\"result-text\">$(html_esc "$rdesc")</span></div>"$'\n'
                ;;
            SKIP)
                sec="${sec}<div class=\"result skip\"><span class=\"badge badge-skip\">SKIP</span><span class=\"result-text\">$(html_esc "$rdesc")</span></div>"$'\n'
                ;;
            FAIL)
                sec="${sec}<div class=\"result fail\"><span class=\"badge badge-fail\">FAIL</span><span class=\"result-text\">$(html_esc "$rdesc")</span>"$'\n'
                cmd="${FAIL_CMD[$rid]}"
                difftext="${FAIL_DIFF[$rid]}"
                if [ -n "$cmd" ]; then
                    sec="${sec}<details><summary>查看详情</summary><div class=\"fail-detail\">"$'\n'
                    sec="${sec}<div class=\"fail-cmd\"><strong>命令:</strong><code>$(html_esc "$cmd")</code></div>"$'\n'
                    if [ -n "$difftext" ]; then
                        sec="${sec}<pre class=\"fail-diff\">$(html_esc "$difftext")</pre>"$'\n'
                    fi
                    sec="${sec}</div></details>"$'\n'
                fi
                sec="${sec}</div>"$'\n'
                ;;
        esac
    done

    sec="${sec}</div></div>"$'\n'
    SECTIONS_HTML="${SECTIONS_HTML}${sec}"
done

# ---- Progress bar ----
PROGRESS_HTML=""
if [ "$T" -gt 0 ]; then
    PROGRESS_HTML="<div class=\"progress-bar\">"$'\n'
    [ "$PP" -gt 0 ] && PROGRESS_HTML="${PROGRESS_HTML}<div class=\"progress-segment progress-pass\" style=\"width:${PP}%\"></div>"$'\n'
    [ "$FP" -gt 0 ] && PROGRESS_HTML="${PROGRESS_HTML}<div class=\"progress-segment progress-fail\" style=\"width:${FP}%\"></div>"$'\n'
    [ "$SP" -gt 0 ] && PROGRESS_HTML="${PROGRESS_HTML}<div class=\"progress-segment progress-skip\" style=\"width:${SP}%\"></div>"$'\n'
    PROGRESS_HTML="${PROGRESS_HTML}</div>"
fi

STATUS_TEXT="全部通过!"
STATUS_CLASS="success"
if [ "$F" -gt 0 ]; then
    STATUS_TEXT="失败数: $F"
    STATUS_CLASS="has-fail"
fi

TIMESTAMP="$(date "+%Y-%m-%d %H:%M:%S")"

# ===== Output HTML =====
cat << HTMLEND
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OHOS Toybox Test Report</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;background:#0f0f23;color:#e0e0e0;line-height:1.6}
.container{max-width:920px;margin:0 auto;padding:20px}
@media(max-width:600px){.container{padding:10px}}
header{text-align:center;padding:30px 0;border-bottom:1px solid #2a2a4e;margin-bottom:30px}
header h1{font-size:1.8em;color:#e8e8ff;margin-bottom:6px;font-weight:700}
header .sub{color:#888;font-size:0.9em}
.summary{background:#161638;border-radius:12px;padding:24px;margin-bottom:24px}
.summary-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}
@media(max-width:600px){.summary-grid{grid-template-columns:repeat(2,1fr)}}
.summary-item{border-radius:8px;padding:16px 12px;text-align:center}
.summary-item.total{background:#1e1e4a}
.summary-item.pass{background:#0d2b1a}
.summary-item.fail{background:#2b0d0d}
.summary-item.skip{background:#2b2b0d}
.summary-item .num{font-size:2em;font-weight:700;line-height:1.2}
.summary-item.total .num{color:#fff}
.summary-item.pass .num{color:#4caf50}
.summary-item.fail .num{color:#f44336}
.summary-item.skip .num{color:#ff9800}
.summary-item .lbl{font-size:0.8em;color:#999;margin-top:4px}
.progress-bar{display:flex;height:14px;border-radius:7px;background:#2a2a4e;overflow:hidden;margin-top:16px}
.progress-segment{height:100%;transition:width .6s ease}
.progress-pass{background:#4caf50}
.progress-fail{background:#f44336}
.progress-skip{background:#ff9800}
.status-banner{text-align:center;padding:12px;border-radius:8px;margin:16px 0 0;font-size:1.05em;font-weight:600}
.status-banner.success{background:#0d2b1a;color:#4caf50}
.status-banner.has-fail{background:#2b0d0d;color:#f44336}
.section{background:#161638;border-radius:12px;padding:24px;margin-bottom:20px}
.section-title{font-size:1.15em;color:#e8e8ff;margin-bottom:14px;padding-bottom:10px;border-bottom:1px solid #2a2a4e}
.board-list{list-style:none;display:flex;flex-wrap:wrap;gap:8px}
.board-list li{display:inline-flex;align-items:center;gap:6px;padding:4px 12px;border-radius:4px;font-size:0.85em;font-family:'Consolas','Courier New',monospace}
.board-list li.ok{background:#0d2b1a;color:#4caf50;border:1px solid #1a5a2a}
.board-list li.no{background:#2b0d0d;color:#f44336;border:1px solid #5a1a1a}
.badge-ok,.badge-no{font-weight:bold;font-size:0.9em}
.results{display:flex;flex-direction:column;gap:8px}
.result{padding:10px 14px;border-radius:6px;font-size:0.9em;display:flex;align-items:flex-start;gap:10px;flex-wrap:wrap}
.result.pass{background:rgba(76,175,80,0.08);border-left:3px solid #4caf50}
.result.fail{background:rgba(244,67,54,0.08);border-left:3px solid #f44336}
.result.skip{background:rgba(255,152,0,0.08);border-left:3px solid #ff9800}
.badge{flex-shrink:0;display:inline-block;padding:2px 8px;border-radius:3px;font-size:0.75em;font-weight:bold;text-transform:uppercase}
.badge-pass{background:#4caf50;color:#fff}
.badge-fail{background:#f44336;color:#fff}
.badge-skip{background:#ff9800;color:#000}
.result-text{flex:1;padding-top:2px}
details{width:100%;margin-top:4px}
details summary{cursor:pointer;color:#888;font-size:0.85em;padding:4px 0;user-select:none}
details summary:hover{color:#ccc}
.fail-detail{margin-top:8px;padding:12px;background:#0a0a1e;border-radius:6px;overflow-x:auto}
.fail-cmd{margin-bottom:8px}
.fail-cmd code{display:block;padding:8px;background:#12122a;border-radius:4px;font-family:'Consolas','Courier New',monospace;font-size:0.85em;color:#e0e0e0;word-break:break-all;white-space:pre-wrap;margin-top:4px}
.fail-diff{padding:10px;background:#12122a;border-radius:4px;font-family:'Consolas','Courier New',monospace;font-size:0.85em;color:#d0d0d0;overflow-x:auto;white-space:pre-wrap;line-height:1.5;margin-top:4px}
footer{text-align:center;padding:20px;color:#555;font-size:0.85em}
</style>
</head>
<body>
<div class="container">
  <header>
    <h1>OHOS Toybox Test Report</h1>
    <div class="sub">$TIMESTAMP</div>
  </header>

  <div class="summary">
    <div class="summary-grid">
      <div class="summary-item total"><div class="num">$T</div><div class="lbl">总计</div></div>
      <div class="summary-item pass"><div class="num">$P</div><div class="lbl">通过</div></div>
      <div class="summary-item fail"><div class="num">$F</div><div class="lbl">失败</div></div>
      <div class="summary-item skip"><div class="num">$S</div><div class="lbl">跳过</div></div>
    </div>
    $PROGRESS_HTML
    <div class="status-banner $STATUS_CLASS">$STATUS_TEXT</div>
  </div>

  ${BOARD_HTML}

  ${SECTIONS_HTML}

  <footer>Generated: $TIMESTAMP</footer>
</div>
</body>
</html>
HTMLEND
