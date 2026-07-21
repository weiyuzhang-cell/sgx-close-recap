#!/bin/bash
# SGX Close Recap — 每日自动生成并发布（本机 launchd 调用）
# 存档式：每天写 recaps/<date>.html（永久 URL）→ 重建首页 index.html → git push（GitHub Pages 上线）
# 故障安全：任何一步失败或校验不过，都不 push，保留线上上一版。全程写日志。

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

REPO="$HOME/sgx-close-recap"
LOG="$HOME/Library/Logs/sgx-close-recap.log"
TOKEN_FILE="$HOME/.config/sgx-close-recap/token"
TODAY="$(date +%Y-%m-%d)"
OUT="recaps/${TODAY}.html"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$LOG"; }
log "==== run start ($TODAY) ===="

# 0) 鉴权 token
if [ ! -s "$TOKEN_FILE" ]; then log "ERROR: token 文件缺失 $TOKEN_FILE"; exit 1; fi
export CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

# 1) 交易日校验（SGX；休市则跳过）
DAYS="$(longbridge trading days SG --start "$TODAY" --end "$TODAY" 2>>"$LOG" || true)"
if ! echo "$DAYS" | grep -q "$TODAY"; then
  log "今天非 SGX 交易日，跳过。"; log "==== run end (skipped) ===="; exit 0
fi

# 2) 同步仓库
cd "$REPO" || { log "ERROR: 无法进入 $REPO"; exit 1; }
git pull -q 2>>"$LOG" || log "WARN: git pull 失败，继续"

# 3) 以最近一篇为结构模板，生成今天的 recaps/<date>.html
LATEST="$(ls recaps/*.html 2>/dev/null | sort | tail -1)"
[ -z "$LATEST" ] && { log "ERROR: 无模板（recaps/ 为空）"; exit 1; }
PROMPT="用 sgx-close-recap skill 生成今天（${TODAY}，SGT）的坡股收盘复盘。\
以 ${LATEST} 作为**精确结构模板**：产出一份**新文件 ${OUT}**，结构与模板完全一致（完整 HTML 文档含 <!doctype>；\
三个 <article class=\"recap\"> 对应 en/zh-CN/zh-TW；两个 h2.recap-subhead 小标题；\
末尾 <script type=\"application/json\" id=\"sgx-recap-data\"> 内嵌 JSON 换成今天内容，date 字段=${TODAY}）。\
只把内容换成今天的，结构/样式/脚本保持不变。**不要调用 Artifact 工具**，**不要改动其它已存在的 recaps 文件或 index.html**。\
确保内嵌 JSON 可被 JSON.parse。按 skill 要求更新 running-threads 状态（状态文件在 ~/.claude/skills/sgx-close-recap/state/running-threads.md）。\
若 ${OUT} 已存在，**直接覆盖重写、不要询问确认**（这是当天的重新生成）。完成后不需要额外输出。"

log "调用 claude 生成 $OUT …"
claude -p "$PROMPT" --dangerously-skip-permissions >>"$LOG" 2>&1 < /dev/null
[ $? -ne 0 ] && { log "ERROR: claude 非零退出，中止（不 push）"; exit 1; }

# 4) 校验今天这篇：doctype + 内嵌 JSON 合法 + 三语齐 + date 正确
if ! python3 - "$REPO/$OUT" "$TODAY" <<'PY' 2>>"$LOG"
import sys, re, json
h=open(sys.argv[1],encoding='utf-8').read(); today=sys.argv[2]
assert h.lstrip().lower().startswith('<!doctype'), 'missing <!doctype>'
m=re.search(r'<script type="application/json" id="sgx-recap-data">(.*?)</script>',h,re.S); assert m,'missing JSON'
d=json.loads(m.group(1)); assert d['date']==today, f"date {d['date']}!={today}"
for k in ('en','zh-CN','zh-TW'):
    assert d['content'][k]['title'] and d['content'][k]['body'], f'empty {k}'
print('validate ok', d['date'])
PY
then
  log "ERROR: $OUT 校验不过，中止（不 push）"; rm -f "$REPO/$OUT"; exit 1
fi

# 5) 重建首页存档列表
python3 "$REPO/scripts/build-index.py" >>"$LOG" 2>&1 || { log "ERROR: build-index 失败"; exit 1; }

# 6) 提交并推送
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  log "无变化，不提交。"; log "==== run end (no change) ===="; exit 0
fi
git add -A 2>>"$LOG"
git -c user.name="weiyuzhang-cell" -c user.email="weiyuzhang-cell@users.noreply.github.com" \
    commit -qm "SGX close recap — ${TODAY}" 2>>"$LOG"
if git push -q 2>>"$LOG"; then
  log "已推送 ${OUT} + 首页，GitHub Pages 将更新。"; log "==== run end (published $TODAY) ===="
else
  log "ERROR: git push 失败"; exit 1
fi
