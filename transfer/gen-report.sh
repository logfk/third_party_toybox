#!/bin/bash
# gen-report.sh - Parse OHOS Toybox test output and generate HTML report
# Usage: ./run-board.sh 2>&1 | ./gen-report.sh [output_dir]
# If output_dir provided, generates multi-page report structure.
# If not, outputs single-page HTML to stdout (backward compatible).
# Compatible with Git Bash (Windows), bash 3.2+

OUTPUT_DIR="${1:-}"

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

    # ----- DETAIL section marker: end FAIL collection -----
    if [[ "$line" == "===== DETAIL:"*"=====" ]]; then
        IN_FAIL=false
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

# ---- Parse DETAIL sections (appended by run-board.sh) ----
declare -a DTL_CMD DTL_NAME DTL_RESULT DTL_TEXT
_IN_DTL=false
_DTL_CMD=""
_DTL_BUF=""
_DTL_NAME=""
_DTL_RES=""
for ((_i=0; _i<${#INPUT[@]}; _i++)); do
    _line="${INPUT[$_i]}"
    if [[ "$_line" == "===== DETAIL:"*"=====" ]]; then
        if [ -n "$_DTL_BUF" ] && [ -n "$_DTL_NAME" ]; then
            DTL_CMD+=("$_DTL_CMD"); DTL_NAME+=("$_DTL_NAME")
            DTL_RESULT+=("$_DTL_RES"); DTL_TEXT+=("$_DTL_BUF")
        fi
        _IN_DTL=true
        _DTL_CMD="${_line#===== DETAIL: }"; _DTL_CMD="${_DTL_CMD% =====}"
        _DTL_BUF=""; _DTL_NAME=""; _DTL_RES=""
        continue
    fi
    if [ "$_IN_DTL" = true ]; then
        if [[ "$_line" == "["*"]"* ]]; then
            [ -n "$_DTL_BUF" ] && [ -n "$_DTL_NAME" ] && {
                DTL_CMD+=("$_DTL_CMD"); DTL_NAME+=("$_DTL_NAME")
                DTL_RESULT+=("$_DTL_RES"); DTL_TEXT+=("$_DTL_BUF")
            }
            _rest="${_line#*] }"
            _DTL_RES="${_rest%% *}"
            _name_rest="${_rest#* }"
            _DTL_NAME="${_name_rest%%|*}"; _DTL_NAME="${_DTL_NAME% }"
            _DTL_BUF="${_line}"$'\n'
        elif [[ "$_line" == "  "* ]]; then
            _DTL_BUF="${_DTL_BUF}${_line}"$'\n'
        elif [[ "$_line" == "====="* ]]; then
            [ -n "$_DTL_NAME" ] && {
                DTL_CMD+=("$_DTL_CMD"); DTL_NAME+=("$_DTL_NAME")
                DTL_RESULT+=("$_DTL_RES"); DTL_TEXT+=("$_DTL_BUF")
            }
            _IN_DTL=false
            _DTL_NAME=""
            _DTL_BUF=""
        fi
    fi
done
[ -n "$_DTL_BUF" ] && [ -n "$_DTL_NAME" ] && {
    DTL_CMD+=("$_DTL_CMD"); DTL_NAME+=("$_DTL_NAME")
    DTL_RESULT+=("$_DTL_RES"); DTL_TEXT+=("$_DTL_BUF")
}

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

TIMESTAMP="$(date "+%Y-%m-%d %H:%M:%S")"

# ---- JSON-encode data for embedding in HTML ----
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

JSON_BOARD_OK="["
sep=""
for cmd in "${BOARD_OK[@]}"; do
    JSON_BOARD_OK="${JSON_BOARD_OK}${sep}\"$(json_escape "$cmd")\""
    sep=","
done
JSON_BOARD_OK="${JSON_BOARD_OK}]"

JSON_BOARD_NO="["
sep=""
for cmd in "${BOARD_NO[@]}"; do
    JSON_BOARD_NO="${JSON_BOARD_NO}${sep}\"$(json_escape "$cmd")\""
    sep=","
done
JSON_BOARD_NO="${JSON_BOARD_NO}]"

JSON_SECTIONS="["
sep=""
for s in "${SECTIONS[@]}"; do
    JSON_SECTIONS="${JSON_SECTIONS}${sep}\"$(json_escape "$s")\""
    sep=","
done
JSON_SECTIONS="${JSON_SECTIONS}]"

JSON_RESULTS="["
sep=""
for r in "${RESULTS[@]}"; do
    type="${r%%:*}"
    rest="${r#*: }"
    [ "$rest" = "$r" ] && rest="${r#*:}"
    JSON_RESULTS="${JSON_RESULTS}${sep}{\"type\":\"$(json_escape "$type")\",\"desc\":\"$(json_escape "$rest")\"}"
    sep=","
done
JSON_RESULTS="${JSON_RESULTS}]"

JSON_RES_SECTION="["
sep=""
for rs in "${RES_SECTION[@]}"; do
    JSON_RES_SECTION="${JSON_RES_SECTION}${sep}$rs"
    sep=","
done
JSON_RES_SECTION="${JSON_RES_SECTION}]"

JSON_FAIL_CMD="["
sep=""
for fc in "${FAIL_CMD[@]}"; do
    JSON_FAIL_CMD="${JSON_FAIL_CMD}${sep}\"$(json_escape "$fc")\""
    sep=","
done
JSON_FAIL_CMD="${JSON_FAIL_CMD}]"

JSON_FAIL_DIFF="["
sep=""
for fd in "${FAIL_DIFF[@]}"; do
    JSON_FAIL_DIFF="${JSON_FAIL_DIFF}${sep}\"$(json_escape "$fd")\""
    sep=","
done
JSON_FAIL_DIFF="${JSON_FAIL_DIFF}]"

JSON_DETAIL="["
sep=""
for ((_di=0; _di<${#DTL_CMD[@]}; _di++)); do
    JSON_DETAIL="${JSON_DETAIL}${sep}{\"cmd\":\"$(json_escape "${DTL_CMD[$_di]}")\",\"name\":\"$(json_escape "${DTL_NAME[$_di]}")\",\"result\":\"$(json_escape "${DTL_RESULT[$_di]}")\",\"text\":\"$(json_escape "${DTL_TEXT[$_di]}")\"}"
    sep=","
done
JSON_DETAIL="${JSON_DETAIL}]"

# ==========================================================================
# Common CSS
# ==========================================================================
COMMON_CSS='
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;background:#0f0f23;color:#e0e0e0;line-height:1.6}
.container{max-width:960px;margin:0 auto;padding:20px}
@media(max-width:600px){.container{padding:10px}}
header{text-align:center;padding:30px 0;border-bottom:1px solid #2a2a4e;margin-bottom:30px}
header h1{font-size:1.8em;color:#e8e8ff;margin-bottom:6px;font-weight:700}
header .sub{color:#888;font-size:0.9em}
.section{background:#161638;border-radius:12px;padding:24px;margin-bottom:20px}
.section-title{font-size:1.15em;color:#e8e8ff;margin-bottom:14px;padding-bottom:10px;border-bottom:1px solid #2a2a4e}
.board-list{list-style:none;display:flex;flex-wrap:wrap;gap:8px;max-height:110px;overflow-y:auto;padding-right:4px}
.board-list::-webkit-scrollbar{width:6px}
.board-list::-webkit-scrollbar-thumb{background:#3a3a5e;border-radius:3px}
.board-list li{display:inline-flex;align-items:center;gap:6px;padding:4px 12px;border-radius:4px;font-size:0.85em;font-family:"Consolas","Courier New",monospace}
.board-list li.ok{background:#0d2b1a;color:#4caf50;border:1px solid #1a5a2a}
.board-list li.no{background:#2b0d0d;color:#f44336;border:1px solid #5a1a1a}
.badge-ok,.badge-no{font-weight:bold;font-size:0.9em}
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
.nav-bar{background:#161638;border-radius:12px;padding:14px 20px;margin-bottom:20px;display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.nav-bar .back-btn{background:#2e2e5e;color:#e0e0ff;border:none;border-radius:6px;padding:8px 16px;font-size:0.9em;cursor:pointer;transition:background .2s;white-space:nowrap;text-decoration:none;display:inline-block}
.nav-bar .back-btn:hover{background:#3e3e7e}
.nav-bar .breadcrumb{color:#888;font-size:0.9em}
.nav-bar .breadcrumb a{color:#aaa;text-decoration:none}
.nav-bar .breadcrumb a:hover{color:#e0e0ff}
.nav-bar .breadcrumb span{color:#e0e0ff;font-weight:600}
.nav-bar .breadcrumb .sep{margin:0 8px;color:#555}
.command-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}
@media(max-width:600px){.command-grid{grid-template-columns:repeat(2,1fr)}}
@media(max-width:400px){.command-grid{grid-template-columns:1fr}}
.command-card{background:#1a1a3e;border-radius:10px;padding:16px;transition:background .2s,transform .1s;border:1px solid #2a2a4e;position:relative;text-decoration:none;color:inherit;display:block}
.command-card:hover{background:#22224e;transform:translateY(-2px);border-color:#4e4e8e}
.command-card .cmd-name{font-weight:600;color:#e8e8ff;margin-bottom:8px;font-size:1em}
.command-card .cmd-stats{display:flex;gap:8px;flex-wrap:wrap}
.command-card .stat-badge{display:inline-flex;align-items:center;gap:4px;padding:2px 8px;border-radius:3px;font-size:0.75em;font-weight:600}
.command-card .stat-badge.pass{background:#0d2b1a;color:#4caf50;border:1px solid #1a5a2a}
.command-card .stat-badge.fail{background:#2b0d0d;color:#f44336;border:1px solid #5a1a1a}
.command-card .stat-badge.skip{background:#2b2b0d;color:#ff9800;border:1px solid #5a5a1a}
.command-card .stat-badge.total{background:#1e1e4a;color:#aaa;border:1px solid #3a3a5e}
.cmd-header{background:#161638;border-radius:12px;padding:24px;margin-bottom:20px}
.cmd-header .cmd-title{font-size:1.3em;color:#e8e8ff;font-weight:700;margin-bottom:8px}
.cmd-header .cmd-name-monospace{font-family:"Consolas","Courier New",monospace;color:#888;font-size:0.9em}
.cmd-header .cmd-summary-stats{display:flex;gap:12px;margin-top:12px;flex-wrap:wrap}
.cmd-header .cmd-summary-stats .stat{display:inline-flex;align-items:center;gap:6px;padding:4px 12px;border-radius:4px;font-size:0.85em}
.cmd-header .cmd-summary-stats .stat.pass{background:#0d2b1a;color:#4caf50}
.cmd-header .cmd-summary-stats .stat.fail{background:#2b0d0d;color:#f44336}
.cmd-header .cmd-summary-stats .stat.skip{background:#2b2b0d;color:#ff9800}
.test-list{display:flex;flex-direction:column;gap:4px}
.test-row{background:#161638;border-radius:8px;padding:10px 14px;font-size:0.88em;display:flex;align-items:center;gap:10px;border-left:3px solid transparent;transition:background .2s}
.test-row:hover{background:#1a1a3e}
.test-row.pass{border-left-color:#4caf50}
.test-row.fail{border-left-color:#f44336;background:#1e1010}
.test-row.fail:hover{background:#2a1515}
.test-row.skip{border-left-color:#ff9800;background:#1e1e10}
.test-row.skip:hover{background:#2a2a15}
.test-row .badge{flex-shrink:0;display:inline-block;padding:2px 8px;border-radius:3px;font-size:0.75em;font-weight:bold;text-transform:uppercase;min-width:44px;text-align:center}
.test-row .badge-pass{background:#4caf50;color:#fff}
.test-row .badge-fail{background:#f44336;color:#fff}
.test-row .badge-skip{background:#ff9800;color:#000}
.test-row .test-desc{flex:1;padding-top:2px}
.test-row .test-desc .test-purpose{color:#aaa;font-size:0.85em;margin-top:3px;display:block}
.test-row .test-detail-toggle{background:none;border:1px solid #3a3a5e;color:#888;cursor:pointer;font-size:0.78em;padding:2px 8px;border-radius:4px;transition:color .2s,background .2s;flex-shrink:0;white-space:nowrap}
.test-row .test-detail-toggle:hover{color:#e0e0e0;background:#2a2a4e;border-color:#5a5a8e}
.test-detail{width:100%;margin-top:8px;margin-left:-14px;margin-right:-14px;padding:12px 14px;background:#0a0a1e;border-radius:0 0 6px 6px;overflow-x:auto;display:none}
.test-detail.open{display:block}
.fail-cmd{margin-bottom:8px}
.fail-cmd code{display:block;padding:8px;background:#12122a;border-radius:4px;font-family:"Consolas","Courier New",monospace;font-size:0.85em;color:#e0e0e0;word-break:break-all;white-space:pre-wrap;margin-top:4px}
.fail-diff{padding:10px;background:#12122a;border-radius:4px;font-family:"Consolas","Courier New",monospace;font-size:0.85em;color:#d0d0d0;overflow-x:auto;white-space:pre-wrap;line-height:1.5;margin-top:4px}
.detail-log{background:#0a0a1e;border:1px solid #1a1a3e;border-radius:6px;padding:12px;font-family:"Consolas","Courier New",monospace;font-size:0.82em;color:#c0c0c0;overflow-x:auto;white-space:pre-wrap;line-height:1.5;max-height:360px;overflow-y:auto;margin-top:6px}
.toggle-all-btn{background:#2a2a4e;color:#aaa;border:1px solid #3a3a5e;border-radius:4px;padding:2px 10px;font-size:0.8em;cursor:pointer;margin-left:8px}
.toggle-all-btn:hover{color:#e0e0e0;background:#3a3a5e}
footer{text-align:center;padding:20px;color:#555;font-size:0.85em}
.hidden{display:none!important}
'

# ==========================================================================
# Multi-page mode: generate folder structure
# ==========================================================================
if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR/commands"

    # Save data.json
    printf '{\n  "boardOk": %s,\n  "boardNo": %s,\n  "sections": %s,\n  "results": %s,\n  "resSection": %s,\n  "failCmd": %s,\n  "failDiff": %s,\n  "detail": %s\n}\n' \
        "$JSON_BOARD_OK" "$JSON_BOARD_NO" "$JSON_SECTIONS" "$JSON_RESULTS" \
        "$JSON_RES_SECTION" "$JSON_FAIL_CMD" "$JSON_FAIL_DIFF" "$JSON_DETAIL" \
        > "$OUTPUT_DIR/data.json"

    # Save stats.txt: total pass fail skip
    printf '%d %d %d %d\n' "$T" "$P" "$F" "$S" > "$OUTPUT_DIR/stats.txt"

    # ----- Generate run dashboard (index.html) -----
    cat > "$OUTPUT_DIR/index.html" << DASHEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OHOS Toybox Test Report - $TIMESTAMP</title>
<style>$COMMON_CSS</style>
</head>
<body>
<div class="container">
  <header>
    <h1>OHOS Toybox Test Report</h1>
    <div class="sub">$TIMESTAMP</div>
  </header>
  <div class="nav-bar">
    <a href="../index.html" class="back-btn">&larr; 返回总览</a>
  </div>
  <div id="report-root"></div>
  <footer>Generated: $TIMESTAMP</footer>
</div>
<script>
var RD = {
  boardOk: $JSON_BOARD_OK,
  boardNo: $JSON_BOARD_NO,
  sections: $JSON_SECTIONS,
  results: $JSON_RESULTS,
  resSection: $JSON_RES_SECTION,
  failCmd: $JSON_FAIL_CMD,
  failDiff: $JSON_FAIL_DIFF
};
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function cnt(r){var p=0,f=0,s=0;for(var i=0;i<r.length;i++){if(r[i].type==='PASS')p++;else if(r[i].type==='FAIL')f++;else if(r[i].type==='SKIP')s++}return{pass:p,fail:f,skip:s,total:p+f+s}}
function cmdSt(si){var c=[];for(var i=0;i<RD.results.length;i++){if(RD.resSection[i]===si)c.push(RD.results[i])}return cnt(c)}
function inferP(cmd,d){var k={'help':'验证 --help 参数能正常输出用法说明','no args':'验证无参数时输出错误信息并返回非零退出码','bad flag':'验证无效参数被正确拒绝','invalid':'验证无效输入被正确拒绝','usage':'验证命令用法说明','basic':'验证命令基本功能正常','empty':'验证空输入场景处理','stdin':'验证从标准输入读取数据'};var lo=d.toLowerCase();for(var x in k){if(lo.indexOf(x)!==-1)return k[x]}var m=d.match(/^(-[a-z]|--[a-z][a-z-]+)/);if(m)return '测试 '+esc(m[1])+' 参数功能';return ''}
function render(){
  var st=cnt(RD.results),t=st.total,h='';
  var pp=t>0?Math.round(st.pass*100/t):0,fp=t>0?Math.round(st.fail*100/t):0,sp=t>0?Math.round(st.skip*100/t):0;
  h+='<div class="summary"><div class="summary-grid">';
  h+='<div class="summary-item total"><div class="num">'+t+'</div><div class="lbl">总计</div></div>';
  h+='<div class="summary-item pass"><div class="num">'+st.pass+'</div><div class="lbl">通过</div></div>';
  h+='<div class="summary-item fail"><div class="num">'+st.fail+'</div><div class="lbl">失败</div></div>';
  h+='<div class="summary-item skip"><div class="num">'+st.skip+'</div><div class="lbl">跳过</div></div>';
  h+='</div>';
  if(t>0){h+='<div class="progress-bar">';if(pp>0)h+='<div class="progress-segment progress-pass" style="width:'+pp+'%"></div>';if(fp>0)h+='<div class="progress-segment progress-fail" style="width:'+fp+'%"></div>';if(sp>0)h+='<div class="progress-segment progress-skip" style="width:'+sp+'%"></div>';h+='</div>'}
  h+='<div class="status-banner '+(st.fail>0?'has-fail':'success')+'">'+(st.fail>0?'失败数: '+st.fail:'全部通过!')+'</div></div>';
  if(RD.boardOk.length>0||RD.boardNo.length>0){h+='<div class="section"><h2 class="section-title">主板命令支持</h2><ul class="board-list">';for(var i=0;i<RD.boardOk.length;i++)h+='<li class="ok"><span class="badge-ok">OK</span> '+esc(RD.boardOk[i])+'</li>';for(var i=0;i<RD.boardNo.length;i++)h+='<li class="no"><span class="badge-no">--</span> '+esc(RD.boardNo[i])+'</li>';h+='</ul></div>'}
  h+='<div class="section"><h2 class="section-title">命令列表 <span style="color:#888;font-weight:400;font-size:0.85em">('+RD.sections.length+' 个命令)</span></h2><div class="command-grid">';
  for(var si=0;si<RD.sections.length;si++){var cs=cmdSt(si);var cn=RD.sections[si];var safeCn=cn.replace(/[^a-zA-Z0-9_\-]/g,'_');h+='<a class="command-card" href="commands/'+safeCn+'.html" title="点击查看 '+esc(cn)+' 的测试详情">';h+='<div class="cmd-name">'+esc(cn)+'</div><div class="cmd-stats">';h+='<span class="stat-badge total">'+cs.total+' 项</span>';if(cs.pass>0)h+='<span class="stat-badge pass">'+cs.pass+' PASS</span>';if(cs.fail>0)h+='<span class="stat-badge fail">'+cs.fail+' FAIL</span>';if(cs.skip>0)h+='<span class="stat-badge skip">'+cs.skip+' SKIP</span>';h+='</div></a>'}
  h+='</div></div>';
  document.getElementById('report-root').innerHTML=h;
}
render();
</script>
</body>
</html>
DASHEOF
    echo "  生成: $OUTPUT_DIR/index.html"

    # ----- Generate per-command pages -----
    for ((si=0; si<${#SECTIONS[@]}; si++)); do
        CMDNAME="${SECTIONS[$si]}"
        SAFE_CMDNAME=$(printf '%s' "$CMDNAME" | sed 's/[^a-zA-Z0-9_-]/_/g')
        CMD_FILE="$OUTPUT_DIR/commands/${SAFE_CMDNAME}.html"

        # Build filtered arrays for THIS command only
        C_PASS=0; C_FAIL=0; C_SKIP=0; C_TOTAL=0
        CMD_RESULTS=""
        CMD_FAIL_CMD=""
        CMD_FAIL_DIFF=""
        CMD_DETAIL=""
        _cr_sep=""; _cf_sep=""; _cd_sep=""; _dt_sep=""
        for ((ri=0; ri<${#RESULTS[@]}; ri++)); do
            [ "${RES_SECTION[$ri]}" -eq "$si" ] || continue
            C_TOTAL=$((C_TOTAL+1))
            case "${RESULTS[$ri]%%:*}" in
                PASS) C_PASS=$((C_PASS+1)) ;;
                FAIL) C_FAIL=$((C_FAIL+1)) ;;
                SKIP) C_SKIP=$((C_SKIP+1)) ;;
            esac
            _type="${RESULTS[$ri]%%:*}"
            _rest="${RESULTS[$ri]#*: }"
            [ "$_rest" = "${RESULTS[$ri]}" ] && _rest="${RESULTS[$ri]#*:}"
            CMD_RESULTS="${CMD_RESULTS}${_cr_sep}{\"type\":\"$(json_escape "$_type")\",\"desc\":\"$(json_escape "$_rest")\"}"
            _cr_sep=","
            CMD_FAIL_CMD="${CMD_FAIL_CMD}${_cf_sep}\"$(json_escape "${FAIL_CMD[$ri]}")\""
            _cf_sep=","
            CMD_FAIL_DIFF="${CMD_FAIL_DIFF}${_cd_sep}\"$(json_escape "${FAIL_DIFF[$ri]}")\""
            _cd_sep=","
        done
        CMD_RESULTS="[${CMD_RESULTS}]"
        CMD_FAIL_CMD="[${CMD_FAIL_CMD}]"
        CMD_FAIL_DIFF="[${CMD_FAIL_DIFF}]"

        # Build filtered detail entries for THIS command
        for ((_di=0; _di<${#DTL_CMD[@]}; _di++)); do
            [ "${DTL_CMD[$_di]}" = "$CMDNAME" ] || continue
            CMD_DETAIL="${CMD_DETAIL}${_dt_sep}{\"name\":\"$(json_escape "${DTL_NAME[$_di]}")\",\"result\":\"$(json_escape "${DTL_RESULT[$_di]}")\",\"text\":\"$(json_escape "${DTL_TEXT[$_di]}")\"}"
            _dt_sep=","
        done
        CMD_DETAIL="[${CMD_DETAIL}]"

        SAFE_CMDNAME_JSON=$(json_escape "$CMDNAME")

        cat > "$CMD_FILE" << CMDEOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>${CMDNAME} - OHOS Toybox Test Report</title>
<style>$COMMON_CSS</style>
</head>
<body>
<div class="container">
  <header>
    <h1>OHOS Toybox Test Report</h1>
    <div class="sub">$TIMESTAMP</div>
  </header>
  <div id="report-root"></div>
  <footer>Generated: $TIMESTAMP</footer>
</div>
<script>
var RD={results:$CMD_RESULTS,failCmd:$CMD_FAIL_CMD,failDiff:$CMD_FAIL_DIFF,detail:$CMD_DETAIL};
var CMD_NAME="$SAFE_CMDNAME_JSON";
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function cnt(r){var p=0,f=0,s=0;for(var i=0;i<r.length;i++){if(r[i].type==='PASS')p++;else if(r[i].type==='FAIL')f++;else if(r[i].type==='SKIP')s++}return{pass:p,fail:f,skip:s,total:p+f+s}}
function getDet(name){for(var i=0;i<RD.detail.length;i++){if(RD.detail[i].name===name)return RD.detail[i].text}return ''}
function inferP(cmd,d){var k={'help':'验证 --help 参数能正常输出用法说明','no args':'验证无参数时输出错误信息并返回非零退出码','bad flag':'验证无效参数被正确拒绝','invalid':'验证无效输入被正确拒绝','usage':'验证命令用法说明','basic':'验证命令基本功能正常','empty':'验证空输入场景处理','stdin':'验证从标准输入读取数据'};var lo=d.toLowerCase();for(var x in k){if(lo.indexOf(x)!==-1)return k[x]}var m=d.match(/^(-[a-z]|--[a-z][a-z-]+)/);if(m)return '测试 '+esc(m[1])+' 参数功能';return ''}
function toggleDetail(id){var el=document.getElementById(id);if(el)el.classList.toggle('open')}
function toggleAll(){var ds=document.querySelectorAll('.test-detail');var any=false;for(var i=0;i<ds.length;i++){if(!ds[i].classList.contains('open')){any=true;break}}for(var i=0;i<ds.length;i++){if(any)ds[i].classList.add('open');else ds[i].classList.remove('open')}}
function render(){
  var cs=cnt(RD.results);var h='';
  h+='<div class="nav-bar"><a href="../index.html" class="back-btn">&larr; 返回总览</a>';
  h+='<div class="breadcrumb"><a href="../index.html">测试总览</a><span class="sep">/</span><span>'+esc(CMD_NAME)+'</span></div></div>';
  h+='<div class="cmd-header"><div class="cmd-title">'+esc(CMD_NAME)+'</div>';
  h+='<div class="cmd-name-monospace">命令测试详情</div>';
  h+='<div class="cmd-summary-stats">';
  h+='<span class="stat total" style="background:#1e1e4a;color:#aaa">总计: '+cs.total+'</span>';
  if(cs.pass>0)h+='<span class="stat pass">通过: '+cs.pass+'</span>';
  if(cs.fail>0)h+='<span class="stat fail">失败: '+cs.fail+'</span>';
  if(cs.skip>0)h+='<span class="stat skip">跳过: '+cs.skip+'</span>';
  h+='</div></div>';
  h+='<h2 style="font-size:1em;color:#e8e8ff;margin-bottom:12px">测试用例 <button class="toggle-all-btn" onclick="toggleAll()">全部展开/折叠</button></h2>';
  h+='<div class="test-list">';
  for(var ri=0;ri<RD.results.length;ri++){
    var r=RD.results[ri];var rl=r.type.toLowerCase();
    h+='<div class="test-row '+rl+'">';
    h+='<span class="badge badge-'+rl+'">'+r.type+'</span>';
    var purp=inferP(CMD_NAME,r.desc);
    h+='<div class="test-desc"><span class="test-purpose">'+esc(r.desc)+'</span>';
    if(purp)h+='<span class="test-purpose" style="color:#777;font-size:0.8em;margin-top:2px">'+purp+'</span>';
    h+='</div>';
    var dt=getDet(r.desc);
    if(dt||(r.type==='FAIL'&&RD.failCmd[ri])){
      var did='d-'+ri;
      h+='<button class="test-detail-toggle" onclick="toggleDetail(\''+did+'\')">详情</button>';
      h+='</div><div id="'+did+'" class="test-detail">';
      if(dt){h+='<pre class="detail-log">'+esc(dt)+'</pre>'}
      else if(r.type==='FAIL'&&RD.failCmd[ri]){h+='<div class="fail-cmd"><strong>命令:</strong><code>'+esc(RD.failCmd[ri])+'</code></div>';if(RD.failDiff[ri])h+='<pre class="fail-diff">'+esc(RD.failDiff[ri])+'</pre>'}
      h+='</div>';
    }else{h+='</div>'}
  }
  h+='</div>';
  document.getElementById('report-root').innerHTML=h;
}
render();
</script>
</body>
</html>
CMDEOF
    done
    echo "  生成: $OUTPUT_DIR/commands/ (${#SECTIONS[@]} 个命令页面)"

    exit 0
fi

# ==========================================================================
# Single-page mode (backward compatible): output to stdout
# ==========================================================================
cat << HTMLEND
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OHOS Toybox Test Report - $TIMESTAMP</title>
<style>$COMMON_CSS</style>
</head>
<body>
<div class="container">
  <header>
    <h1>OHOS Toybox Test Report</h1>
    <div class="sub">$TIMESTAMP</div>
  </header>
  <div id="report-root"></div>
</div>
<script>
var REPORT_DATA = {
    boardOk: $JSON_BOARD_OK,
    boardNo: $JSON_BOARD_NO,
    sections: $JSON_SECTIONS,
    results: $JSON_RESULTS,
    resSection: $JSON_RES_SECTION,
    failCmd: $JSON_FAIL_CMD,
    failDiff: $JSON_FAIL_DIFF,
    detail: $JSON_DETAIL
};
function escHtml(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')}
function countResults(results){var p=0,f=0,s=0;for(var i=0;i<results.length;i++){if(results[i].type==='PASS')p++;else if(results[i].type==='FAIL')f++;else if(results[i].type==='SKIP')s++}return{pass:p,fail:f,skip:s,total:p+f+s}}
function getCmdStats(sidx){var c=[];for(var i=0;i<REPORT_DATA.results.length;i++){if(REPORT_DATA.resSection[i]===sidx)c.push(REPORT_DATA.results[i])}return countResults(c)}
function getDetail(cmd,name){for(var i=0;i<REPORT_DATA.detail.length;i++){var d=REPORT_DATA.detail[i];if(d.cmd===cmd&&d.name===name)return d.text}return ''}
function inferPurpose(cmd,desc){var known={'help':'验证 --help 参数能正常输出用法说明','no args':'验证无参数时输出错误信息并返回非零退出码','bad flag':'验证无效参数被正确拒绝','invalid':'验证无效输入被正确拒绝','usage':'验证命令用法说明','basic':'验证命令基本功能正常','empty':'验证空输入场景处理','stdin':'验证从标准输入读取数据'};var lower=desc.toLowerCase();for(var k in known){if(lower.indexOf(k)!==-1)return known[k]}var m=desc.match(/^(-[a-z]|--[a-z][a-z-]+)/);if(m)return '测试 '+escHtml(m[1])+' 参数功能';return ''}
function renderDashboard(){var st=countResults(REPORT_DATA.results);var t=st.total;var pp=t>0?Math.round(st.pass*100/t):0;var fp=t>0?Math.round(st.fail*100/t):0;var sp=t>0?Math.round(st.skip*100/t):0;var h='';h+='<div class="summary"><div class="summary-grid">';h+='<div class="summary-item total"><div class="num">'+t+'</div><div class="lbl">总计</div></div>';h+='<div class="summary-item pass"><div class="num">'+st.pass+'</div><div class="lbl">通过</div></div>';h+='<div class="summary-item fail"><div class="num">'+st.fail+'</div><div class="lbl">失败</div></div>';h+='<div class="summary-item skip"><div class="num">'+st.skip+'</div><div class="lbl">跳过</div></div>';h+='</div>';if(t>0){h+='<div class="progress-bar">';if(pp>0)h+='<div class="progress-segment progress-pass" style="width:'+pp+'%"></div>';if(fp>0)h+='<div class="progress-segment progress-fail" style="width:'+fp+'%"></div>';if(sp>0)h+='<div class="progress-segment progress-skip" style="width:'+sp+'%"></div>';h+='</div>'}h+='<div class="status-banner '+(st.fail>0?'has-fail':'success')+'">'+(st.fail>0?'失败数: '+st.fail:'全部通过!')+'</div></div>';if(REPORT_DATA.boardOk.length>0||REPORT_DATA.boardNo.length>0){h+='<div class="section"><h2 class="section-title">主板命令支持</h2><ul class="board-list">';for(var i=0;i<REPORT_DATA.boardOk.length;i++)h+='<li class="ok"><span class="badge-ok">OK</span> '+escHtml(REPORT_DATA.boardOk[i])+'</li>';for(var i=0;i<REPORT_DATA.boardNo.length;i++)h+='<li class="no"><span class="badge-no">--</span> '+escHtml(REPORT_DATA.boardNo[i])+'</li>';h+='</ul></div>'}h+='<div class="section"><h2 class="section-title">命令列表 <span style="color:#888;font-weight:400;font-size:0.85em">('+REPORT_DATA.sections.length+' 个命令)</span></h2><div class="command-grid">';for(var si=0;si<REPORT_DATA.sections.length;si++){var cs=getCmdStats(si);h+='<div class="command-card" onclick="showCommand('+si+')" title="点击查看 '+escHtml(REPORT_DATA.sections[si])+' 的测试详情">';h+='<div class="cmd-name">'+escHtml(REPORT_DATA.sections[si])+'</div><div class="cmd-stats">';h+='<span class="stat-badge total">'+cs.total+' 项</span>';if(cs.pass>0)h+='<span class="stat-badge pass">'+cs.pass+' PASS</span>';if(cs.fail>0)h+='<span class="stat-badge fail">'+cs.fail+' FAIL</span>';if(cs.skip>0)h+='<span class="stat-badge skip">'+cs.skip+' SKIP</span>';h+='</div></div>'}h+='</div></div>';h+='<footer>Generated: '+new Date().toLocaleString()+'</footer>';document.getElementById('report-root').innerHTML=h}
function showCommand(sidx){var cmdName=REPORT_DATA.sections[sidx];var cs=getCmdStats(sidx);var h='';h+='<div class="nav-bar"><button class="back-btn" onclick="renderDashboard()">&larr; 返回总览</button><div class="breadcrumb"><span>测试总览</span><span class="sep">/</span><span>'+escHtml(cmdName)+'</span></div></div>';h+='<div class="cmd-header"><div class="cmd-title">'+escHtml(cmdName)+'</div><div class="cmd-name-monospace">命令测试详情</div><div class="cmd-summary-stats">';h+='<span class="stat total" style="background:#1e1e4a;color:#aaa">总计: '+cs.total+'</span>';if(cs.pass>0)h+='<span class="stat pass">通过: '+cs.pass+'</span>';if(cs.fail>0)h+='<span class="stat fail">失败: '+cs.fail+'</span>';if(cs.skip>0)h+='<span class="stat skip">跳过: '+cs.skip+'</span>';h+='</div></div>';h+='<h2 style="font-size:1em;color:#e8e8ff;margin-bottom:12px">测试用例 <button class="toggle-all-btn" onclick="toggleAllDetail()">全部展开/折叠</button></h2>';h+='<div class="test-list">';for(var ri=0;ri<REPORT_DATA.results.length;ri++){if(REPORT_DATA.resSection[ri]!==sidx)continue;var r=REPORT_DATA.results[ri];var rl=r.type.toLowerCase();h+='<div class="test-row '+rl+'"><span class="badge badge-'+rl+'">'+r.type+'</span>';var purp=inferPurpose(cmdName,r.desc);h+='<div class="test-desc"><span class="test-purpose">'+escHtml(r.desc)+'</span>';if(purp)h+='<span class="test-purpose" style="color:#777;font-size:0.8em;margin-top:2px">'+purp+'</span>';h+='</div>';var dt=getDetail(cmdName,r.desc);if(dt||(r.type==='FAIL'&&REPORT_DATA.failCmd[ri])){var did='d-'+sidx+'-'+ri;h+='<button class="test-detail-toggle" onclick="toggleDetail(\''+did+'\')">详情</button>';h+='</div><div id="'+did+'" class="test-detail">';if(dt){h+='<pre class="detail-log">'+escHtml(dt)+'</pre>'}else if(r.type==='FAIL'&&REPORT_DATA.failCmd[ri]){h+='<div class="fail-cmd"><strong>命令:</strong><code>'+escHtml(REPORT_DATA.failCmd[ri])+'</code></div>';if(REPORT_DATA.failDiff[ri])h+='<pre class="fail-diff">'+escHtml(REPORT_DATA.failDiff[ri])+'</pre>'}h+='</div>'}else{h+='</div>'}}h+='</div>';document.getElementById('report-root').innerHTML=h;window.scrollTo(0,0)}
function toggleDetail(id){var el=document.getElementById(id);if(el)el.classList.toggle('open')}
function toggleAllDetail(){var ds=document.querySelectorAll('.test-detail');var any=false;for(var i=0;i<ds.length;i++){if(!ds[i].classList.contains('open')){any=true;break}}for(var i=0;i<ds.length;i++){if(any)ds[i].classList.add('open');else ds[i].classList.remove('open')}}
renderDashboard();
</script>
</body>
</html>
HTMLEND
