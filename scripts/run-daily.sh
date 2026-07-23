#!/bin/bash
# SGX Close Recap — 每日自动生成并发布（本机 launchd 调用，硬化版）
# 流程：fetch-data.py 确定性取数(Yahoo行情+Metabase UV+CLI基本面)→data.json
#      → claude 只照 data.json 写三语稿 → 校验 → 重建存档首页 → git push（GitHub Pages 上线）
# 故障安全：任何一步失败或校验不过都不 push，保留线上上一版。全程写日志。

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

REPO="/Users/patrickwave/新加坡股市收盘skill/site"
LOG="/Users/patrickwave/新加坡股市收盘skill/logs/sgx-close-recap.log"
TOKEN_FILE="/Users/patrickwave/新加坡股市收盘skill/config/token"
TODAY="$(date +%Y-%m-%d)"
OUT="recaps/${TODAY}.html"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$LOG"; }
log "==== run start ($TODAY) ===="

[ -s "$TOKEN_FILE" ] || { log "ERROR: claude token 缺失"; exit 1; }
export CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
cd "$REPO" || { log "ERROR: 无法进入 $REPO"; exit 1; }
git pull -q 2>>"$LOG" || log "WARN: git pull 失败，继续"

# 1) 确定性取数 → data.json
log "取数 fetch-data.py …"
python3 scripts/fetch-data.py "$TODAY" >>"$LOG" 2>&1 || { log "ERROR: fetch-data 失败，中止"; exit 1; }

# 2) 交易日 / 数据完整性校验
python3 - "$REPO/data.json" "$TODAY" <<'PY' 2>>"$LOG" || { log "非交易日或数据不全，跳过（不 push）"; log "==== run end (skipped) ===="; exit 0; }
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8')); today=sys.argv[2]
assert d.get("is_trading_day"), "not a trading day"
assert d.get("index",{}).get("close"), "no STI close"
assert d["index"]["actual_date"]==today, f"STI date {d['index'].get('actual_date')}!={today}(可能未收盘)"
assert d.get("selected_movers"), "no movers"
print("data ok")
PY

# 2.5) 生成三语「坡股今日人气榜」PNG → recaps/assets/（失败或无当日 UV 不影响正文）
log "生成人气榜 PNG …"
python3 leaderboard/build-leaderboard.py "$TODAY" >>"$LOG" 2>&1 || log "WARN: 人气榜出图失败，正文照常发"

# 3) Claude 只照 data.json 写三语稿（不许自己找行情/定方向/选股）
LATEST="$(ls recaps/*.html 2>/dev/null | sort | grep -v "/${TODAY}.html$" | tail -1)"
[ -z "$LATEST" ] && LATEST="$(ls recaps/*.html 2>/dev/null | sort | tail -1)"
PROMPT="用 sgx-close-recap skill 生成今天(${TODAY}, SGT)的坡股收盘复盘。\
**所有事实只从本仓库根目录的 ./data.json 读取**：index(STI 收盘/涨跌/高低)、uv_ranking(读者关注榜)、\
basket(全成分涨跌)、selected_movers(已选定的个股，含 change_pct/direction；cli_events=公司业务事件[主]、cli_valuation/cli_rating=估值评级[次])。\
**严禁自己去查行情、算涨跌、定方向或另选个股**——个股就写 selected_movers 里这几只，涨跌方向与幅度用它给的值；\
**个股段以事件为主线**：每只先讲 cli_events 里的具体业务事件/催化剂(订单/合约/评级调整/并购注资/获奖/财报，带事件里的数字)，写清发生了什么+为何与走势相关；\
估值/目标价(cli_valuation/cli_rating)至多一句点缀，无合适事件时不硬凑财务数字，cli_events 为空则只据实写涨跌幅+板块、不编事件。The Tell 可参考 basket 的领涨领跌结构。\
**不要写「读者关注 Top10 / 人气榜」段，也不要在正文或内嵌 JSON 里放榜单数据或榜单图**——每日人气榜 PNG 由流水线在你写完后自动附到每个语言块末尾。若 ${LATEST} 模板里有 figure.recap-leaderboard 之类的旧榜单图，删掉别抄。\
以 ${LATEST} 为精确结构模板，产出 ./${OUT}（完整 HTML；三个 <article class=recap> en/zh-CN/zh-TW；两个 h2.recap-subhead；\
末尾 <script id=sgx-recap-data> 内嵌 JSON 换成今天内容、date=${TODAY}，JSON 顶层不需要 uv_top10）。**不要调用 Artifact**。\
若 ${OUT} 已存在直接覆盖、不要询问。确保内嵌 JSON 可 JSON.parse。按 skill 更新 running-threads。完成不必额外输出。"

log "调用 claude 写稿（照 data.json）…"
claude -p "$PROMPT" --dangerously-skip-permissions >>"$LOG" 2>&1 < /dev/null || { log "ERROR: claude 非零退出，中止"; exit 1; }

# 4) 校验产出
python3 - "$REPO/$OUT" "$TODAY" <<'PY' 2>>"$LOG" || { log "ERROR: $OUT 校验不过，中止（不 push）"; rm -f "$REPO/$OUT"; exit 1; }
import json,sys,re
h=open(sys.argv[1],encoding='utf-8').read(); today=sys.argv[2]
assert h.lstrip().lower().startswith('<!doctype')
d=json.loads(re.search(r'id="sgx-recap-data">(.*?)</script>',h,re.S).group(1))
assert d['date']==today
for k in ('en','zh-CN','zh-TW'): assert d['content'][k]['title'] and d['content'][k]['body']
print("output ok")
PY

# 4.5) 确定性把人气榜图注入每语言 <article> 末尾（不依赖 claude；无图则自动跳过）
python3 - "$REPO/$OUT" "$TODAY" <<'PY' 2>>"$LOG" || log "WARN: 榜单图注入失败，正文照常"
import sys, os, re
path, today = sys.argv[1], sys.argv[2]
h = open(path, encoding="utf-8").read()
assets = os.path.join(os.path.dirname(path), "assets")
alt = {"en": "SGX Most Watched Today", "zh-CN": "坡股今日人气榜", "zh-TW": "坡股今日人氣榜"}
n = 0
for lang in ("en", "zh-CN", "zh-TW"):
    png = f"{today}-{lang}.png"
    if not os.path.exists(os.path.join(assets, png)):
        continue
    fig = (f'<figure class="recap-leaderboard" style="margin:32px 0;text-align:center">'
           f'<img src="assets/{png}" alt="{alt[lang]} · {today}" '
           f'style="max-width:min(100%,460px);width:100%;height:auto;border-radius:14px;'
           f'box-shadow:0 2px 16px rgba(0,0,0,.08)"></figure>')
    m = re.search(r'<article[^>]*data-lang="' + re.escape(lang) + r'".*?</article>', h, re.S)
    if not m:
        continue
    art = re.sub(r'\s*<figure class="recap-leaderboard".*?</figure>', '', m.group(0), flags=re.S)  # 去旧图
    subs = list(re.finditer(r'<h2[^>]*recap-subhead', art))
    if len(subs) >= 2:                       # 插在第2个小标题(The Tell)前 = 个股焦点节之后
        pos = subs[1].start()
        art = art[:pos] + fig + art[pos:]
    else:                                    # 兜底：文末
        art = art.replace('</article>', fig + '</article>', 1)
    h = h[:m.start()] + art + h[m.end():]
    n += 1
open(path, "w", encoding="utf-8").write(h)
print(f"leaderboard images injected: {n}")
PY

# 5) 重建存档首页
python3 scripts/build-index.py >>"$LOG" 2>&1 || { log "ERROR: build-index 失败"; exit 1; }

# 6) 提交推送
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  log "无变化，不提交。"; log "==== run end (no change) ===="; exit 0
fi
git add -A 2>>"$LOG"
git -c user.name="weiyuzhang-cell" -c user.email="weiyuzhang-cell@users.noreply.github.com" commit -qm "SGX close recap — ${TODAY}" 2>>"$LOG"
if git push -q 2>>"$LOG"; then
  log "已推送 ${OUT} + 首页。"; log "==== run end (published $TODAY) ===="
else
  log "ERROR: git push 失败"; exit 1
fi
