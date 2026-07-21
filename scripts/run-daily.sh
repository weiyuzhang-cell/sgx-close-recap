#!/bin/bash
# SGX Close Recap — 每日自动生成并发布（本机 launchd 调用）
# 流程：交易日校验 → claude 生成 index.html → 校验内嵌JSON → git push（GitHub Pages 自动上线）
# 故障安全：任何一步失败或校验不过，都不 push，保留线上上一版。全程写日志。

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

REPO="$HOME/sgx-close-recap"
LOG="$HOME/Library/Logs/sgx-close-recap.log"
TOKEN_FILE="$HOME/.config/sgx-close-recap/token"
TODAY="$(date +%Y-%m-%d)"

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*" >> "$LOG"; }

log "==== run start ($TODAY) ===="

# 0) 鉴权 token
if [ ! -s "$TOKEN_FILE" ]; then log "ERROR: token 文件缺失 $TOKEN_FILE，先跑 claude setup-token"; exit 1; fi
export CLAUDE_CODE_OAUTH_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

# 1) 交易日校验（SGX；休市则跳过）
DAYS="$(longbridge trading days SG --start "$TODAY" --end "$TODAY" 2>>"$LOG" || true)"
if ! echo "$DAYS" | grep -q "$TODAY"; then
  log "今天非 SGX 交易日，跳过。"
  log "==== run end (skipped) ===="
  exit 0
fi

# 2) 同步仓库
cd "$REPO" || { log "ERROR: 无法进入 $REPO"; exit 1; }
git pull -q 2>>"$LOG" || log "WARN: git pull 失败，继续"

# 3) 跑 Claude 生成今天的 index.html（headless）
PROMPT="用 sgx-close-recap skill 生成今天（${TODAY}，SGT）的坡股收盘复盘。\
本仓库根目录的 ./index.html 是上一期页面，作为**精确结构模板**：产出后**覆盖写回 ./index.html**，\
保持完全相同的结构（完整 HTML 文档含 <!doctype>；三个 <article class=\"recap\"> 对应 en/zh-CN/zh-TW；\
两个 h2.recap-subhead 小标题；末尾 <script type=\"application/json\" id=\"sgx-recap-data\"> 内嵌 JSON 换成今天内容）。\
只把内容换成今天的，结构/样式/脚本保持不变。**不要调用 Artifact 工具**。确保内嵌 JSON 可被 JSON.parse。\
按 skill 要求更新 running-threads 状态。完成后不需要额外输出。"

log "调用 claude 生成中…"
claude -p "$PROMPT" --dangerously-skip-permissions >>"$LOG" 2>&1
CL=$?
if [ $CL -ne 0 ]; then log "ERROR: claude 退出码 $CL，中止（不 push）"; exit 1; fi

# 4) 推送前校验：index.html 内嵌 JSON 合法 + 三语齐 + 有 doctype
if ! python3 - "$REPO/index.html" <<'PY' 2>>"$LOG"
import sys, re, json
h = open(sys.argv[1], encoding='utf-8').read()
assert h.lstrip().lower().startswith('<!doctype'), 'missing <!doctype>'
m = re.search(r'<script type="application/json" id="sgx-recap-data">(.*?)</script>', h, re.S)
assert m, 'missing embedded JSON'
d = json.loads(m.group(1))
for k in ('en','zh-CN','zh-TW'):
    assert d['content'][k]['title'] and d['content'][k]['body'], f'empty {k}'
print('validate ok', d.get('date'))
PY
then
  log "ERROR: index.html 校验不过，中止（不 push，线上保留上一版）"
  git checkout -- index.html 2>>"$LOG" || true
  exit 1
fi

# 5) 无变化则不提交
if git diff --quiet -- index.html; then
  log "index.html 无变化，不提交。"
  log "==== run end (no change) ===="
  exit 0
fi

# 6) 提交并推送 → GitHub Pages 自动重建
git add -A 2>>"$LOG"
git -c user.name="weiyuzhang-cell" -c user.email="weiyuzhang-cell@users.noreply.github.com" \
    commit -qm "SGX close recap — ${TODAY}" 2>>"$LOG"
if git push -q 2>>"$LOG"; then
  log "已推送，GitHub Pages 将自动更新。"
  log "==== run end (published $TODAY) ===="
else
  log "ERROR: git push 失败"
  exit 1
fi
