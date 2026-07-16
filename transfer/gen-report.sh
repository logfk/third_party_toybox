#!/bin/bash
# gen-report.sh - Parse OHOS Toybox test output and generate HTML report
# Architecture: awk parses log -> temp files -> single python3 call generates all HTML.
# Usage: ./run-board.sh 2>&1 | ./gen-report.sh [output_dir]

OUTPUT_DIR="${1:-}"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ---- Step 1: awk parses entire log into structured temp files ----
awk -v OUT="$TMPDIR" '
BEGIN { p=0; f=0; s=0; cur_sec=0; in_board=0; in_fail=0; fi=0 }
function je(str) {
    gsub(/\\/, "\\\\", str)
    gsub(/"/, "\\\"", str)
    gsub(/\t/, "\\t", str)
    gsub(/\r/, "", str)
    gsub(/\n/, "\\n", str)
    return str
}
/检查主板命令支持/ { in_board=1; next }
in_board && /^[[:space:]]*\[OK\]/ { cmd=$0; sub(/^[[:space:]]*\[OK\] /, "", cmd); print cmd > OUT "/board_ok.txt"; next }
in_board && /^[[:space:]]*\[--\]/ { cmd=$0; sub(/^[[:space:]]*\[--\] /, "", cmd); sub(/ \(不支持\)$/, "", cmd); print cmd > OUT "/board_no.txt"; next }
in_board && (/^$/ || /^=/) { in_board=0; if(/^$/) next }
/^=+$/ {
    in_fail=0
    if (getline nl > 0 && nl ~ /^[[:space:]]*测试:/) {
        cur_sec++
        sec_name=nl; sub(/^[[:space:]]*测试: /, "", sec_name)
        print sec_name > OUT "/sections.txt"
    }
    next
}
/===== DETAIL:/ { in_fail=0; next }
/^PASS:/ { in_fail=0; p++; if(cur_sec>0){pc[cur_sec]++;desc=$0;sub(/^PASS: /,"",desc);printf "{\"type\":\"PASS\",\"desc\":\"%s\"}\n",je(desc) >> OUT "/res_" cur_sec ".jsonl"} next }
/^SKIP:/ { in_fail=0; s++; if(cur_sec>0){sc[cur_sec]++;desc=$0;sub(/^SKIP: /,"",desc);printf "{\"type\":\"SKIP\",\"desc\":\"%s\"}\n",je(desc) >> OUT "/res_" cur_sec ".jsonl"} next }
/^FAIL:/ { in_fail=1; f++; if(cur_sec>0){fc[cur_sec]++;fi++;fcmd_idx[cur_sec]=(fcmd_idx[cur_sec]==""?fi:fcmd_idx[cur_sec]" "fi);desc=$0;sub(/^FAIL: /,"",desc);printf "{\"type\":\"FAIL\",\"desc\":\"%s\"}\n",je(desc) >> OUT "/res_" cur_sec ".jsonl";_FCMD[fi]="";_FDIFF[fi]=""} next }
in_fail && cur_sec>0 { _FDIFF[fi]=_FDIFF[fi] $0 "\n" }
END {
    printf "%d %d %d %d\n", p+f+s, p, f, s > OUT "/counts.txt"
    printf "%d\n", cur_sec > OUT "/nsec.txt"
    for (i=1; i<=cur_sec; i++) {
        printf "%d %d %d\n", pc[i]+0, fc[i]+0, sc[i]+0 > OUT "/meta_" i ".txt"
        n=split(fcmd_idx[i], indices, " ")
        for (j=1; j<=n; j++) {
            idx=indices[j]+0
            if (_FCMD[idx] != "" || _FDIFF[idx] != "") {
                printf "%s\n", je(_FCMD[idx]) > OUT "/fcmd_" i ".txt"
                printf "%s\n", je(_FDIFF[idx]) > OUT "/fdiff_" i ".txt"
            }
        }
    }
}
' > /dev/null

# ---- Step 2: Read parsed data into temp JSON files for python3 ----
declare -a SECTIONS
while IFS= read -r line; do SECTIONS+=("$line"); done < "$TMPDIR/sections.txt"

TIMESTAMP="$(date "+%Y-%m-%d %H:%M:%S")"

echo "$TIMESTAMP" > "$TMPDIR/ts.txt"
read -r T P F S < "$TMPDIR/counts.txt"
echo "$T $P $F $S" > "$TMPDIR/counts2.txt"

# Write all JSON data to temp files
_json_arr() { local _o="[" _s="" _e; for _e in "$@"; do _o="${_o}${_s}\"$(printf '%s' "$_e" | sed 's/\\/\\\\/g; s/"/\\"/g')\""; _s=","; done; printf '%s]' "$_o"; }

declare -a B_OK B_NO
[ -f "$TMPDIR/board_ok.txt" ] && while IFS= read -r _l; do B_OK+=("$_l"); done < "$TMPDIR/board_ok.txt"
[ -f "$TMPDIR/board_no.txt" ] && while IFS= read -r _l; do B_NO+=("$_l"); done < "$TMPDIR/board_no.txt"

_json_arr "${B_OK[@]}" > "$TMPDIR/bok.json" 2>/dev/null || echo "[]" > "$TMPDIR/bok.json"
_json_arr "${B_NO[@]}" > "$TMPDIR/bno.json" 2>/dev/null || echo "[]" > "$TMPDIR/bno.json"
_json_arr "${SECTIONS[@]}" > "$TMPDIR/sec.json"

# Build combined results array + resSection mapping
JSON_RES="["; JSON_RS="["; _s=""; _rs=""
for ((si=0; si<${#SECTIONS[@]}; si++)); do
    _p=0; _f=0; _s2=0
    [ -f "$TMPDIR/meta_$((si+1)).txt" ] && read -r _p _f _s2 < "$TMPDIR/meta_$((si+1)).txt"
    _cnt=$((_p+_f+_s2))
    for ((_j=0; _j<_cnt; _j++)); do JSON_RS="${JSON_RS}${_rs}${si}"; _rs=","; done
    if [ -f "$TMPDIR/res_$((si+1)).jsonl" ]; then
        while IFS= read -r _jl; do [ -n "$_jl" ] && { JSON_RES="${JSON_RES}${_s}${_jl}"; _s=","; }; done < "$TMPDIR/res_$((si+1)).jsonl"
    fi
done
echo "${JSON_RES}]" > "$TMPDIR/res.json"
echo "${JSON_RS}]" > "$TMPDIR/rs.json"

# Build fail cmd/diff arrays
JSON_GFC="["; JSON_GFD="["; _s=""; _s2=""
for ((si=0; si<${#SECTIONS[@]}; si++)); do
    _fc=""; _fd=""
    [ -f "$TMPDIR/fcmd_$((si+1)).txt" ] && while IFS= read -r _l; do [ -n "$_fc" ] && _fc="${_fc},"; _fc="${_fc}\"${_l}\""; done < "$TMPDIR/fcmd_$((si+1)).txt"
    [ -f "$TMPDIR/fdiff_$((si+1)).txt" ] && while IFS= read -r _l; do [ -n "$_fd" ] && _fd="${_fd},"; _fd="${_fd}\"${_l}\""; done < "$TMPDIR/fdiff_$((si+1)).txt"
    [ -n "$_fc" ] && { JSON_GFC="${JSON_GFC}${_s}${_fc}"; JSON_GFD="${JSON_GFD}${_s2}${_fd}"; _s=","; _s2=","; }
done
echo "${JSON_GFC}]" > "$TMPDIR/gfc.json"
echo "${JSON_GFD}]" > "$TMPDIR/gfd.json"

# Build per-command JSON array
CMD_JSON="["
_cs=""
for ((si=0; si<${#SECTIONS[@]}; si++)); do
    _name=$(printf '%s' "${SECTIONS[$si]}" | sed 's/\\/\\\\/g; s/"/\\"/g')
    _cj="["
    _sep=""
    if [ -f "$TMPDIR/res_$((si+1)).jsonl" ]; then
        while IFS= read -r _jl; do [ -n "$_jl" ] && { _cj="${_cj}${_sep}${_jl}"; _sep=","; }; done < "$TMPDIR/res_$((si+1)).jsonl"
    fi
    _cj="${_cj}]"
    _fc="[]"; _fd="[]"
    [ -f "$TMPDIR/fcmd_$((si+1)).txt" ] && { _fc="["; _fs=""; while IFS= read -r _l; do _fc="${_fc}${_fs}\"${_l}\""; _fs=","; done < "$TMPDIR/fcmd_$((si+1)).txt"; _fc="${_fc}]"; }
    [ -f "$TMPDIR/fdiff_$((si+1)).txt" ] && { _fd="["; _fs=""; while IFS= read -r _l; do _fd="${_fd}${_fs}\"${_l}\""; _fs=","; done < "$TMPDIR/fdiff_$((si+1)).txt"; _fd="${_fd}]"; }
    _cp=0; _cf=0; _cs2=0
    [ -f "$TMPDIR/meta_$((si+1)).txt" ] && read -r _cp _cf _cs2 < "$TMPDIR/meta_$((si+1)).txt"
    CMD_JSON="${CMD_JSON}${_cs}{\"name\":\"${_name}\",\"pass\":${_cp},\"fail\":${_cf},\"skip\":${_cs2},\"results\":${_cj},\"failCmd\":${_fc},\"failDiff\":${_fd}}"
    _cs=","
done
echo "${CMD_JSON}]" > "$TMPDIR/cmd.json"

mkdir -p "$OUTPUT_DIR/commands"

# Write data.json and stats.txt for backward compat with run-board.sh
printf '%d %d %d %d\n' "$T" "$P" "$F" "$S" > "$OUTPUT_DIR/stats.txt"
# data.json uses raw JSON from temp files
{
    echo '{'
    printf '  "boardOk": %s,\n' "$(cat "$TMPDIR/bok.json")"
    printf '  "boardNo": %s,\n' "$(cat "$TMPDIR/bno.json")"
    printf '  "sections": %s,\n' "$(cat "$TMPDIR/sec.json")"
    printf '  "results": %s,\n' "$(cat "$TMPDIR/res.json")"
    printf '  "resSection": %s,\n' "$(cat "$TMPDIR/rs.json")"
    printf '  "failCmd": %s,\n' "$(cat "$TMPDIR/gfc.json")"
    printf '  "failDiff": %s,\n' "$(cat "$TMPDIR/gfd.json")"
    printf '  "detail": []\n'
    echo '}'
} > "$OUTPUT_DIR/data.json"

# ---- Step 3: Single python3 call generates all HTML ----
python3 -c "
import sys, os, re, json

OUT = sys.argv[1]
TS = open(sys.argv[2]).read().strip()
T, P, F, S = [int(x) for x in open(sys.argv[3]).read().split()]
bok = json.loads(open(sys.argv[4]).read() or '[]')
bno = json.loads(open(sys.argv[5]).read() or '[]')
sec = json.loads(open(sys.argv[6]).read() or '[]')
res = json.loads(open(sys.argv[7]).read() or '[]')
rs = json.loads(open(sys.argv[8]).read() or '[]')
gfc = json.loads(open(sys.argv[9]).read() or '[]')
gfd = json.loads(open(sys.argv[10]).read() or '[]')
cmds = json.loads(open(sys.argv[11]).read() or '[]')

CSS = '*{margin:0;padding:0;box-sizing:border-box}body{font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,\"Helvetica Neue\",Arial,sans-serif;background:#0f0f23;color:#e0e0e0;line-height:1.6}.container{max-width:960px;margin:0 auto;padding:20px}@media(max-width:600px){.container{padding:10px}}header{text-align:center;padding:30px 0;border-bottom:1px solid #2a2a4e;margin-bottom:30px}header h1{font-size:1.8em;color:#e8e8ff;margin-bottom:6px;font-weight:700}header .sub{color:#888;font-size:0.9em}.section{background:#161638;border-radius:12px;padding:24px;margin-bottom:20px}.section-title{font-size:1.15em;color:#e8e8ff;margin-bottom:14px;padding-bottom:10px;border-bottom:1px solid #2a2a4e}.board-list{list-style:none;display:flex;flex-wrap:wrap;gap:8px;max-height:110px;overflow-y:auto;padding-right:4px}.board-list::-webkit-scrollbar{width:6px}.board-list::-webkit-scrollbar-thumb{background:#3a3a5e;border-radius:3px}.board-list li{display:inline-flex;align-items:center;gap:6px;padding:4px 12px;border-radius:4px;font-size:0.85em;font-family:\"Consolas\",\"Courier New\",monospace}.board-list li.ok{background:#0d2b1a;color:#4caf50;border:1px solid #1a5a2a}.board-list li.no{background:#2b0d0d;color:#f44336;border:1px solid #5a1a1a}.badge-ok,.badge-no{font-weight:bold;font-size:0.9em}.summary{background:#161638;border-radius:12px;padding:24px;margin-bottom:24px}.summary-grid{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}@media(max-width:600px){.summary-grid{grid-template-columns:repeat(2,1fr)}}.summary-item{border-radius:8px;padding:16px 12px;text-align:center}.summary-item.total{background:#1e1e4a}.summary-item.pass{background:#0d2b1a}.summary-item.fail{background:#2b0d0d}.summary-item.skip{background:#2b2b0d}.summary-item .num{font-size:2em;font-weight:700;line-height:1.2}.summary-item.total .num{color:#fff}.summary-item.pass .num{color:#4caf50}.summary-item.fail .num{color:#f44336}.summary-item.skip .num{color:#ff9800}.summary-item .lbl{font-size:0.8em;color:#999;margin-top:4px}.progress-bar{display:flex;height:14px;border-radius:7px;background:#2a2a4e;overflow:hidden;margin-top:16px}.progress-segment{height:100%;transition:width .6s ease}.progress-pass{background:#4caf50}.progress-fail{background:#f44336}.progress-skip{background:#ff9800}.status-banner{text-align:center;padding:12px;border-radius:8px;margin:16px 0 0;font-size:1.05em;font-weight:600}.status-banner.success{background:#0d2b1a;color:#4caf50}.status-banner.has-fail{background:#2b0d0d;color:#f44336}.nav-bar{background:#161638;border-radius:12px;padding:14px 20px;margin-bottom:20px;display:flex;align-items:center;gap:12px;flex-wrap:wrap}.nav-bar .back-btn{background:#2e2e5e;color:#e0e0ff;border:none;border-radius:6px;padding:8px 16px;font-size:0.9em;cursor:pointer;transition:background .2s;white-space:nowrap;text-decoration:none;display:inline-block}.nav-bar .back-btn:hover{background:#3e3e7e}.nav-bar .breadcrumb{color:#888;font-size:0.9em}.nav-bar .breadcrumb a{color:#aaa;text-decoration:none}.nav-bar .breadcrumb a:hover{color:#e0e0ff}.nav-bar .breadcrumb span{color:#e0e0ff;font-weight:600}.nav-bar .breadcrumb .sep{margin:0 8px;color:#555}.command-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px}@media(max-width:600px){.command-grid{grid-template-columns:repeat(2,1fr)}}@media(max-width:400px){.command-grid{grid-template-columns:1fr}}.command-card{background:#1a1a3e;border-radius:10px;padding:16px;transition:background .2s,transform .1s;border:1px solid #2a2a4e;position:relative;text-decoration:none;color:inherit;display:block}.command-card:hover{background:#22224e;transform:translateY(-2px);border-color:#4e4e8e}.command-card .cmd-name{font-weight:600;color:#e8e8ff;margin-bottom:8px;font-size:1em}.command-card .cmd-stats{display:flex;gap:8px;flex-wrap:wrap}.command-card .stat-badge{display:inline-flex;align-items:center;gap:4px;padding:2px 8px;border-radius:3px;font-size:0.75em;font-weight:600}.command-card .stat-badge.pass{background:#0d2b1a;color:#4caf50;border:1px solid #1a5a2a}.command-card .stat-badge.fail{background:#2b0d0d;color:#f44336;border:1px solid #5a1a1a}.command-card .stat-badge.skip{background:#2b2b0d;color:#ff9800;border:1px solid #5a5a1a}.command-card .stat-badge.total{background:#1e1e4a;color:#aaa;border:1px solid #3a3a5e}.cmd-header{background:#161638;border-radius:12px;padding:24px;margin-bottom:20px}.cmd-header .cmd-title{font-size:1.3em;color:#e8e8ff;font-weight:700;margin-bottom:8px}.cmd-header .cmd-name-monospace{font-family:\"Consolas\",\"Courier New\",monospace;color:#888;font-size:0.9em}.cmd-header .cmd-summary-stats{display:flex;gap:12px;margin-top:12px;flex-wrap:wrap}.cmd-header .cmd-summary-stats .stat{display:inline-flex;align-items:center;gap:6px;padding:4px 12px;border-radius:4px;font-size:0.85em}.cmd-header .cmd-summary-stats .stat.pass{background:#0d2b1a;color:#4caf50}.cmd-header .cmd-summary-stats .stat.fail{background:#2b0d0d;color:#f44336}.cmd-header .cmd-summary-stats .stat.skip{background:#2b2b0d;color:#ff9800}.test-list{display:flex;flex-direction:column;gap:4px}.test-row{background:#161638;border-radius:8px;padding:10px 14px;font-size:0.88em;display:flex;align-items:center;gap:10px;border-left:3px solid transparent;transition:background .2s}.test-row:hover{background:#1a1a3e}.test-row.pass{border-left-color:#4caf50}.test-row.fail{border-left-color:#f44336;background:#1e1010}.test-row.fail:hover{background:#2a1515}.test-row.skip{border-left-color:#ff9800;background:#1e1e10}.test-row.skip:hover{background:#2a2a15}.test-row .badge{flex-shrink:0;display:inline-block;padding:2px 8px;border-radius:3px;font-size:0.75em;font-weight:bold;text-transform:uppercase;min-width:44px;text-align:center}.test-row .badge-pass{background:#4caf50;color:#fff}.test-row .badge-fail{background:#f44336;color:#fff}.test-row .badge-skip{background:#ff9800;color:#000}.test-row .test-desc{flex:1;padding-top:2px}.test-row .test-desc .test-purpose{color:#aaa;font-size:0.85em;margin-top:3px;display:block}.test-row .test-detail-toggle{background:none;border:1px solid #3a3a5e;color:#888;cursor:pointer;font-size:0.78em;padding:2px 8px;border-radius:4px;transition:color .2s,background .2s;flex-shrink:0;white-space:nowrap}.test-row .test-detail-toggle:hover{color:#e0e0e0;background:#2a2a4e;border-color:#5a5a8e}.test-detail{width:100%;margin-top:8px;margin-left:-14px;margin-right:-14px;padding:12px 14px;background:#0a0a1e;border-radius:0 0 6px 6px;overflow-x:auto;display:none}.test-detail.open{display:block}.fail-cmd{margin-bottom:8px}.fail-cmd code{display:block;padding:8px;background:#12122a;border-radius:4px;font-family:\"Consolas\",\"Courier New\",monospace;font-size:0.85em;color:#e0e0e0;word-break:break-all;white-space:pre-wrap;margin-top:4px}.fail-diff{padding:10px;background:#12122a;border-radius:4px;font-family:\"Consolas\",\"Courier New\",monospace;font-size:0.85em;color:#d0d0d0;overflow-x:auto;white-space:pre-wrap;line-height:1.5;margin-top:4px}.detail-log{background:#0a0a1e;border:1px solid #1a1a3e;border-radius:6px;padding:12px;font-family:\"Consolas\",\"Courier New\",monospace;font-size:0.82em;color:#c0c0c0;overflow-x:auto;white-space:pre-wrap;line-height:1.5;max-height:360px;overflow-y:auto;margin-top:6px}.toggle-all-btn{background:#2a2a4e;color:#aaa;border:1px solid #3a3a5e;border-radius:4px;padding:2px 10px;font-size:0.8em;cursor:pointer;margin-left:8px}.toggle-all-btn:hover{color:#e0e0e0;background:#3a3a5e}footer{text-align:center;padding:20px;color:#555;font-size:0.85em}'

JS = 'function esc(s){return String(s).replace(/&/g,\"&amp;\").replace(/</g,\"&lt;\").replace(/>/g,\"&gt;\").replace(/\"/g,\"&quot;\")}function cnt(r){var p=0,f=0,s=0;for(var i=0;i<r.length;i++){if(r[i].type===\"PASS\")p++;else if(r[i].type===\"FAIL\")f++;else if(r[i].type===\"SKIP\")s++}return{pass:p,fail:f,skip:s,total:p+f+s}}function inferP(d){var k={\"help\":\"验证 --help 参数能正常输出用法说明\",\"no args\":\"验证无参数时输出错误信息并返回非零退出码\",\"bad flag\":\"验证无效参数被正确拒绝\",\"invalid\":\"验证无效输入被正确拒绝\",\"usage\":\"验证命令用法说明\",\"basic\":\"验证命令基本功能正常\",\"empty\":\"验证空输入场景处理\",\"stdin\":\"验证从标准输入读取数据\"};var lo=d.toLowerCase();for(var x in k){if(lo.indexOf(x)!==-1)return k[x]}var m=d.match(/^(-[a-z]|--[a-z][a-z-]+)/);if(m)return \"测试 \"+esc(m[1])+\" 参数功能\";return \"\"}'

def esc(s): return str(s).replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('\"','&quot;')
def cnt(r):
    p=f=s=0
    for x in r:
        if x['type']=='PASS': p+=1
        elif x['type']=='FAIL': f+=1
        elif x['type']=='SKIP': s+=1
    return {'pass':p,'fail':f,'skip':s,'total':p+f+s}

st = cnt(res); t = st['total']
pp = round(st['pass']*100/t) if t else 0
fp = round(st['fail']*100/t) if t else 0
sp = round(st['skip']*100/t) if t else 0

h = '<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1.0\"><title>OHOS Toybox Test Report</title><style>'+CSS+'</style></head><body>'
h += '<div class=\"container\"><header><h1>OHOS Toybox Test Report</h1><div class=\"sub\">'+TS+'</div></header>'
h += '<div id=\"report-root\"></div><footer>Generated: '+TS+'</footer></div>'
h += '<script>\nvar RD={boardOk:'+json.dumps(bok)+',boardNo:'+json.dumps(bno)+',sections:'+json.dumps(sec)+',results:'+json.dumps(res)+',resSection:'+json.dumps(rs)+',failCmd:'+json.dumps(gfc)+',failDiff:'+json.dumps(gfd)+'};\n'
h += JS+'\n'
h += 'function cmdSt(si){var c=[];for(var i=0;i<RD.results.length;i++){if(RD.resSection[i]===si)c.push(RD.results[i])}return cnt(c)}\n'
h += 'function render(){var st=cnt(RD.results),t=st.total,h=\"\";var pp=t>0?Math.round(st.pass*100/t):0,fp=t>0?Math.round(st.fail*100/t):0,sp=t>0?Math.round(st.skip*100/t):0;h+=\"<div class=\\\"summary\\\"><div class=\\\"summary-grid\\\">\";h+=\"<div class=\\\"summary-item total\\\"><div class=\\\"num\\\">\"+t+\"</div><div class=\\\"lbl\\\">总计</div></div>\";h+=\"<div class=\\\"summary-item pass\\\"><div class=\\\"num\\\">\"+st.pass+\"</div><div class=\\\"lbl\\\">通过</div></div>\";h+=\"<div class=\\\"summary-item fail\\\"><div class=\\\"num\\\">\"+st.fail+\"</div><div class=\\\"lbl\\\">失败</div></div>\";h+=\"<div class=\\\"summary-item skip\\\"><div class=\\\"num\\\">\"+st.skip+\"</div><div class=\\\"lbl\\\">跳过</div></div>\";h+=\"</div>\";if(t>0){h+=\"<div class=\\\"progress-bar\\\">\";if(pp>0)h+=\"<div class=\\\"progress-segment progress-pass\\\" style=\\\"width:\"+pp+\"%\\\"></div>\";if(fp>0)h+=\"<div class=\\\"progress-segment progress-fail\\\" style=\\\"width:\"+fp+\"%\\\"></div>\";if(sp>0)h+=\"<div class=\\\"progress-segment progress-skip\\\" style=\\\"width:\"+sp+\"%\\\"></div>\";h+=\"</div>\"}h+=\"<div class=\\\"status-banner \"+(st.fail>0?\"has-fail\":\"success\")+\"\\\">\"+(st.fail>0?\"失败数: \"+st.fail:\"全部通过!\")+\"</div></div>\";if(RD.boardOk.length>0||RD.boardNo.length>0){h+=\"<div class=\\\"section\\\"><h2 class=\\\"section-title\\\">主板命令支持</h2><ul class=\\\"board-list\\\">\";for(var i=0;i<RD.boardOk.length;i++)h+=\"<li class=\\\"ok\\\"><span class=\\\"badge-ok\\\">OK</span> \"+esc(RD.boardOk[i])+\"</li>\";for(var i=0;i<RD.boardNo.length;i++)h+=\"<li class=\\\"no\\\"><span class=\\\"badge-no\\\">--</span> \"+esc(RD.boardNo[i])+\"</li>\";h+=\"</ul></div>\"}h+=\"<div class=\\\"section\\\"><h2 class=\\\"section-title\\\">命令列表 <span style=\\\"color:#888;font-weight:400;font-size:0.85em\\\">(\"+RD.sections.length+\" 个命令)</span></h2><div class=\\\"command-grid\\\">\";for(var si=0;si<RD.sections.length;si++){var cs=cmdSt(si);var cn=RD.sections[si];var sc=cn.replace(/[^a-zA-Z0-9_-]/g,\"_\");h+=\"<a class=\\\"command-card\\\" href=\\\"commands/\"+sc+\".html\\\">\";h+=\"<div class=\\\"cmd-name\\\">\"+esc(cn)+\"</div><div class=\\\"cmd-stats\\\">\";h+=\"<span class=\\\"stat-badge total\\\">\"+cs.total+\" 项</span>\";if(cs.pass>0)h+=\"<span class=\\\"stat-badge pass\\\">\"+cs.pass+\" PASS</span>\";if(cs.fail>0)h+=\"<span class=\\\"stat-badge fail\\\">\"+cs.fail+\" FAIL</span>\";if(cs.skip>0)h+=\"<span class=\\\"stat-badge skip\\\">\"+cs.skip+\" SKIP</span>\";h+=\"</div></a>\"}h+=\"</div></div>\";document.getElementById(\"report-root\").innerHTML=h}\n'
h += 'render();\n</script></body></html>'

with open(os.path.join(OUT, 'index.html'), 'w') as f: f.write(h)
print('  生成: '+OUT+'/index.html')

os.makedirs(os.path.join(OUT, 'commands'), exist_ok=True)
for ci, cd in enumerate(cmds):
    cn = cd['name']; cj = cd['results']; cs_cnt = cnt(cj)
    fj = cd.get('failCmd',[]); dj = cd.get('failDiff',[])
    safe = re.sub(r'[^a-zA-Z0-9_-]','_',cn)
    hh = '<!DOCTYPE html><html lang=\"zh-CN\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1.0\"><title>'+esc(cn)+' - OHOS Toybox Test Report</title><style>'+CSS+'</style></head><body>'
    hh += '<div class=\"container\"><header><h1>OHOS Toybox Test Report</h1><div class=\"sub\">'+TS+'</div></header>'
    hh += '<div id=\"report-root\"></div><footer>Generated: '+TS+'</footer></div>'
    hh += '<script>\nvar RD={results:'+json.dumps(cj)+',failCmd:'+json.dumps(fj)+',failDiff:'+json.dumps(dj)+',detail:[]};\nvar CMD_NAME='+json.dumps(cn)+';\n'
    hh += JS+'\n'
    hh += 'function getDet(n){return\"\"}\nfunction toggleDetail(id){var el=document.getElementById(id);if(el)el.classList.toggle(\"open\")}\nfunction toggleAll(){var ds=document.querySelectorAll(\".test-detail\");var any=false;for(var i=0;i<ds.length;i++){if(!ds[i].classList.contains(\"open\")){any=true;break}}for(var i=0;i<ds.length;i++){if(any)ds[i].classList.add(\"open\");else ds[i].classList.remove(\"open\")}}\n'
    hh += 'function render(){var cs=cnt(RD.results);var h=\"\";h+=\"<div class=\\\"nav-bar\\\"><a href=\\\"../index.html\\\" class=\\\"back-btn\\\">&larr; 返回总览</a>\";h+=\"<div class=\\\"breadcrumb\\\"><a href=\\\"../index.html\\\">测试总览</a><span class=\\\"sep\\\">/</span><span>\"+esc(CMD_NAME)+\"</span></div></div>\";h+=\"<div class=\\\"cmd-header\\\"><div class=\\\"cmd-title\\\">\"+esc(CMD_NAME)+\"</div>\";h+=\"<div class=\\\"cmd-name-monospace\\\">命令测试详情</div>\";h+=\"<div class=\\\"cmd-summary-stats\\\">\";h+=\"<span class=\\\"stat total\\\" style=\\\"background:#1e1e4a;color:#aaa\\\">总计: \"+cs.total+\"</span>\";if(cs.pass>0)h+=\"<span class=\\\"stat pass\\\">通过: \"+cs.pass+\"</span>\";if(cs.fail>0)h+=\"<span class=\\\"stat fail\\\">失败: \"+cs.fail+\"</span>\";if(cs.skip>0)h+=\"<span class=\\\"stat skip\\\">跳过: \"+cs.skip+\"</span>\";h+=\"</div></div>\";h+=\"<h2 style=\\\"font-size:1em;color:#e8e8ff;margin-bottom:12px\\\">测试用例 <button class=\\\"toggle-all-btn\\\" onclick=\\\"toggleAll()\\\">全部展开/折叠</button></h2>\";h+=\"<div class=\\\"test-list\\\">\";for(var ri=0;ri<RD.results.length;ri++){var r=RD.results[ri];var rl=r.type.toLowerCase();h+=\"<div class=\\\"test-row \"+rl+\"\\\"><span class=\\\"badge badge-\"+rl+\"\\\">\"+r.type+\"</span>\";var purp=inferP(r.desc);h+=\"<div class=\\\"test-desc\\\"><span class=\\\"test-purpose\\\">\"+esc(r.desc)+\"</span>\";if(purp)h+=\"<span class=\\\"test-purpose\\\" style=\\\"color:#777;font-size:0.8em;margin-top:2px\\\">\"+purp+\"</span>\";h+=\"</div>\";var dt=getDet(r.desc);if(dt||(r.type===\"FAIL\"&&(RD.failCmd[ri]||RD.failDiff[ri]))){var did=\"d-\"+ri;h+=\"<button class=\\\"test-detail-toggle\\\" onclick=\\\"toggleDetail(\\'\"+did+\"\\')\\\">详情</button>\";h+=\"</div><div id=\\\"\"+did+\"\\\" class=\\\"test-detail\\\">\";if(dt){h+=\"<pre class=\\\"detail-log\\\">\"+esc(dt)+\"</pre>\"}else if(r.type===\"FAIL\"){if(RD.failCmd[ri])h+=\"<div class=\\\"fail-cmd\\\"><strong>命令:</strong><code>\"+esc(RD.failCmd[ri])+\"</code></div>\";if(RD.failDiff[ri])h+=\"<pre class=\\\"fail-diff\\\">\"+esc(RD.failDiff[ri])+\"</pre>\"}h+=\"</div>\"}else{h+=\"</div>\"}}h+=\"</div>\";document.getElementById(\"report-root\").innerHTML=h}\nrender();\n</script></body></html>'
    with open(os.path.join(OUT, 'commands', safe+'.html'), 'w') as f: f.write(hh)
print('  生成: '+OUT+'/commands/ ('+str(len(cmds))+' 个命令页面)')
" "$OUTPUT_DIR" "$TMPDIR/ts.txt" "$TMPDIR/counts2.txt" "$TMPDIR/bok.json" "$TMPDIR/bno.json" "$TMPDIR/sec.json" "$TMPDIR/res.json" "$TMPDIR/rs.json" "$TMPDIR/gfc.json" "$TMPDIR/gfd.json" "$TMPDIR/cmd.json"
