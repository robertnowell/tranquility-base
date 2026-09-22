"""Every model call as a page: python3 report.py [out.html]

Reads calls.jsonl and writes one HTML file with each Jev, brain and Pipecat LLM
call in full: the exact state and questions sent, the exact answers, latency.
"""

import html
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CALLS = os.path.join(HERE, "calls.jsonl")
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "calls.html")

CSS = """
body{margin:0;background:#141412;color:#e8e6df;font:13px/1.45 ui-monospace,Menlo,monospace}
main{max-width:1100px;margin:0 auto;padding:24px 16px 80px}
h1{font:600 18px/1.2 ui-sans-serif,-apple-system,sans-serif;letter-spacing:.06em;margin:0 0 4px}
.sub{color:#8a877e;margin:0 0 24px}
.c{border:1px solid #2c2b27;border-radius:6px;margin:0 0 14px;background:#1a1a17}
.h{padding:10px 14px;cursor:pointer;display:flex;gap:14px;align-items:baseline;flex-wrap:wrap}
.h b.k{min-width:52px}.jev b.k{color:#6d8fb5}.brain b.k{color:#c9a75a}.llm b.k{color:#8fb7d8}
.t{color:#8a877e}.sum{color:#c9c6bd}.body{display:none;padding:0 14px 14px}.open .body{display:block}
h3{font:600 11px/1 ui-sans-serif,sans-serif;letter-spacing:.1em;color:#8a877e;margin:14px 0 6px;text-transform:uppercase}
pre{white-space:pre-wrap;word-break:break-word;background:#121210;padding:10px;border-radius:4px;margin:0;font-size:12px;color:#d7d4cb}
.u{color:#f3f1e9}.ans{color:#7fb08a}.q{color:#9fb8d6}
.bar{display:inline-block;height:7px;background:#3d7048;border-radius:3px;vertical-align:middle;margin-right:6px}
"""

def esc(x):
    return html.escape(x if isinstance(x, str) else json.dumps(x, indent=1, ensure_ascii=False))

def ts(t):
    return time.strftime("%H:%M:%S", time.localtime(t)) + f".{int((t % 1) * 10)}"

def render_jev(c):
    st = c["request"].get("state", {}); qs = c["request"].get("questions", {}); ans = c["response"].get("answers", {})
    ad = ans.get("addressed", {}).get("noul"); it = ans.get("intent", {})
    top = sorted((it.get("probabilities") or {}).items(), key=lambda kv: -kv[1])[:4]
    summary = (f'<span class="bar" style="width:{int((ad or 0) * 80)}px"></span>addressed {ad:.2f} · ' if ad is not None else "") + \
              " · ".join(f"{k} {v:.2f}" for k, v in top) + f' · <span class="u">“{esc(str(st.get("utterance", "")))[:90]}”</span>'
    body = "<h3>utterance</h3><pre class='u'>" + esc(str(st.get("utterance", ""))) + "</pre>"
    body += "<h3>state sent (the context Jev saw)</h3><pre>" + esc({k: v for k, v in st.items() if k != "utterance"}) + "</pre>"
    for name, q in qs.items():
        body += f"<h3>question · {esc(name)} ({esc(q.get('type',''))})</h3><pre class='q'>" + esc(q.get("instructions", "")) + "\n\ncriteria:\n" + esc(q.get("criteria", {})) + "</pre>"
    body += "<h3>answers</h3><pre class='ans'>" + esc(ans) + "</pre>"
    return summary, body

def render_brain(c):
    msgs = c["request"].get("messages", []); out = (c["response"].get("choices") or [{}])[0].get("message", {})
    q = msgs[-1]["content"].split("Question: ")[-1] if msgs else ""
    summary = f'<span class="u">“{esc(q)[:80]}”</span> → <span class="ans">{esc(out.get("content") or "")[:120]}</span>'
    body = ""
    for m in msgs:
        body += f"<h3>{esc(m['role'])}</h3><pre>" + esc(m["content"]) + "</pre>"
    body += "<h3>response</h3><pre class='ans'>" + esc(out.get("content") or "") + "</pre>"
    if out.get("reasoning_content") or out.get("reasoning"):
        body += "<h3>reasoning</h3><pre>" + esc(out.get("reasoning_content") or out.get("reasoning")) + "</pre>"
    return summary, body

def render_llm(c):
    req = c["request"]; res = c["response"]; msgs = req.get("messages", [])
    last = msgs[-1] if msgs else {}
    tools = ", ".join(t.get("name", "") for t in res.get("tool_calls", []))
    summary = f'{len(msgs)} messages · last {esc(last.get("role",""))}: <span class="u">{esc(str(last.get("content",""))[:70])}</span> → ' + (f'tools {esc(tools)} ' if tools else "") + f'<span class="ans">{esc(res.get("content") or "")[:100]}</span>'
    body = "<h3>model · tools offered</h3><pre>" + esc({"model": req.get("model"), "tools": [t.get("function", {}).get("name") for t in req.get("tools", []) or []]}) + "</pre>"
    for m in msgs:
        body += f"<h3>{esc(m.get('role',''))}</h3><pre>" + esc(m.get("content") if m.get("content") is not None else m) + "</pre>"
    body += "<h3>response</h3><pre class='ans'>" + esc(res.get("content") or "") + "</pre>"
    if res.get("reasoning"):
        body += "<h3>reasoning</h3><pre>" + esc(res["reasoning"]) + "</pre>"
    if res.get("tool_calls"):
        body += "<h3>tool calls</h3><pre>" + esc(res["tool_calls"]) + "</pre>"
    return summary, body

RENDER = {"jev": render_jev, "brain": render_brain, "llm": render_llm}

def main():
    rows = []
    with open(CALLS, errors="replace") as f:
        for line in f:
            try:
                rows.append(json.loads(line))
            except Exception:
                pass
    parts = []
    for c in rows:
        try:
            summary, body = RENDER.get(c["kind"], render_llm)(c)
        except Exception as e:
            summary, body = f"(unrendered: {esc(str(e))})", "<pre>" + esc(c) + "</pre>"
        parts.append(f'<div class="c {c["kind"]}"><div class="h" onclick="this.parentElement.classList.toggle(\'open\')"><span class="t">{ts(c["t"])}</span><b class="k">{c["kind"]}</b><span class="t">{c.get("ms") or "?"}ms</span><span class="sum">{summary}</span></div><div class="body">{body}</div></div>')
    page = f"""<!DOCTYPE html><html><head><meta charset="utf-8"><title>Tranquility · model calls</title><style>{CSS}</style></head><body><main>
<h1>TRANQUILITY · MODEL CALLS</h1><p class="sub">{len(rows)} calls from calls.jsonl · {time.strftime('%Y-%m-%d %H:%M')} · click a row for the full request and response</p>
{''.join(parts)}</main></body></html>"""
    with open(OUT, "w") as f:
        f.write(page)
    print(OUT, len(rows), "calls")

if __name__ == "__main__":
    main()
