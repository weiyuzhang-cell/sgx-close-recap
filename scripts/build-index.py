#!/usr/bin/env python3
"""扫描 recaps/*.html，读取每篇内嵌 JSON，生成按日期倒序的存档首页 index.html。
纯确定性重建，不依赖 LLM。每篇的永久地址是 recaps/<date>.html。"""
import re, json, glob, os, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
recaps_dir = os.path.join(REPO, "recaps")
entries = []
for fp in glob.glob(os.path.join(recaps_dir, "*.html")):
    html = open(fp, encoding="utf-8").read()
    m = re.search(r'<script type="application/json" id="sgx-recap-data">(.*?)</script>', html, re.S)
    if not m:
        continue
    d = json.loads(m.group(1))
    entries.append({
        "date": d["date"],
        "url": f"recaps/{os.path.basename(fp)}",
        "titles": {k: d["content"][k]["title"] for k in ("en", "zh-CN", "zh-TW")},
    })
entries.sort(key=lambda e: e["date"], reverse=True)

SITE = {
    "en":    {"h1": "SGX Close Recap", "sub": "Daily Singapore market close · Longbridge Singapore"},
    "zh-CN": {"h1": "坡股每日收盘", "sub": "新加坡股市每日收盘复盘 · 长桥新加坡"},
    "zh-TW": {"h1": "坡股每日收盤", "sub": "新加坡股市每日收盤複盤 · 長橋新加坡"},
}

def esc(s): return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))

def list_items(lang):
    rows = []
    for e in entries:
        rows.append(
            f'<li><a href="{e["url"]}"><time datetime="{e["date"]}">{e["date"]}</time>'
            f'<span class="t">{esc(e["titles"][lang])}</span></a></li>'
        )
    return "\n".join(rows)

blocks = "\n".join(
    f'<section class="site active" data-lang="{lang}" lang="{lang}">'
    f'<h1>{SITE[lang]["h1"]}</h1><p class="sub">{SITE[lang]["sub"]}</p>'
    f'<ul class="archive">\n{list_items(lang)}\n</ul></section>'
    if lang == "en" else
    f'<section class="site" data-lang="{lang}" lang="{lang}">'
    f'<h1>{SITE[lang]["h1"]}</h1><p class="sub">{SITE[lang]["sub"]}</p>'
    f'<ul class="archive">\n{list_items(lang)}\n</ul></section>'
    for lang in ("en", "zh-CN", "zh-TW")
)

# 供爬虫发现全部往期的索引
index_json = json.dumps(
    {"type": "sgx_close_recap_index", "count": len(entries),
     "entries": [{"date": e["date"], "url": e["url"], "titles": e["titles"]} for e in entries]},
    ensure_ascii=False)

DOC = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="Daily SGX closing recap archive — Longbridge Singapore.">
<title>SGX Close Recap · Longbridge Singapore</title>
<style>
  :root {{ --bg:#fff; --ink:#1a1a1a; --muted:#6b7280; --line:#e7e9ee; --link:#0a3d62; }}
  @media (prefers-color-scheme: dark) {{ :root {{ --bg:#0f1115; --ink:#e8eaf0; --muted:#9aa3b2; --line:#242832; --link:#7fb0dd; }} }}
  :root[data-theme="light"] {{ --bg:#fff; --ink:#1a1a1a; --muted:#6b7280; --line:#e7e9ee; --link:#0a3d62; }}
  :root[data-theme="dark"] {{ --bg:#0f1115; --ink:#e8eaf0; --muted:#9aa3b2; --line:#242832; --link:#7fb0dd; }}
  * {{ box-sizing:border-box; }}
  body {{ background:var(--bg); color:var(--ink);
    font:17px/1.7 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",Georgia,serif;
    margin:0; padding:44px 20px; }}
  .wrap {{ max-width:680px; margin:0 auto; }}
  .lang-switch {{ font-size:13px; color:var(--muted); margin-bottom:30px; }}
  .lang-switch a {{ color:var(--muted); text-decoration:none; cursor:pointer; padding:0 2px; }}
  .lang-switch a.active {{ color:var(--ink); font-weight:600; border-bottom:1.5px solid var(--ink); }}
  .site {{ display:none; }} .site.active {{ display:block; }}
  h1 {{ font-size:28px; font-weight:700; margin:0 0 6px; letter-spacing:-.01em; }}
  .sub {{ color:var(--muted); font-size:14px; margin:0 0 30px; }}
  ul.archive {{ list-style:none; padding:0; margin:0; }}
  ul.archive li {{ border-top:1px solid var(--line); }}
  ul.archive li:last-child {{ border-bottom:1px solid var(--line); }}
  ul.archive a {{ display:flex; gap:16px; align-items:baseline; padding:16px 2px; text-decoration:none; color:var(--ink); }}
  ul.archive a:hover .t {{ color:var(--link); }}
  ul.archive time {{ color:var(--muted); font-size:14px; font-variant-numeric:tabular-nums; white-space:nowrap; min-width:96px; }}
  ul.archive .t {{ font-weight:600; }}
</style>
</head>
<body>
<div class="wrap">
  <div class="lang-switch">
    <a data-target="en" class="active">EN</a> ·
    <a data-target="zh-CN">简体</a> ·
    <a data-target="zh-TW">繁體</a>
  </div>
  {blocks}
</div>
<script type="application/json" id="sgx-recap-index">
{index_json}
</script>
<script>
  (function () {{
    var sw = document.querySelector('.lang-switch');
    sw.addEventListener('click', function (e) {{
      var a = e.target.closest('a'); if (!a) return;
      var t = a.getAttribute('data-target');
      sw.querySelectorAll('a').forEach(function (x) {{ x.classList.toggle('active', x === a); }});
      document.querySelectorAll('.site').forEach(function (s) {{ s.classList.toggle('active', s.getAttribute('data-lang') === t); }});
    }});
  }})();
</script>
</body>
</html>
"""

open(os.path.join(REPO, "index.html"), "w", encoding="utf-8").write(DOC)
print(f"built index.html with {len(entries)} entries: {[e['date'] for e in entries]}")
