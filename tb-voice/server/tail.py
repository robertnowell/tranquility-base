"""A browser view of the manager's event stream: http://localhost:7861

Tails events.jsonl (one JSON line per event) and bot.log (the gate verdicts) and
streams both to the page over Server-Sent Events. Stdlib only; run with
`python3 tail.py` from this directory or `./tail.sh`.
"""

import http.server
import json
import os
import re
import socketserver
import time

HERE = os.path.dirname(os.path.abspath(__file__))
EVENTS = os.path.join(HERE, "events.jsonl")
LOG = os.path.join(HERE, "bot.log")
PORT = int(os.getenv("TB_TAIL_PORT", "7861"))
GATE = re.compile(r"^(\S+ \S+) \| (\w+)\s+\| .*?(gate p=.*|manager read failed.*|manager turn failed.*|exec .*|Starting tb-voice.*)$")

PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Tranquility · events</title>
<style>
:root{color-scheme:dark}body{margin:0;background:#141412;color:#e8e6df;font:13px/1.45 ui-monospace,Menlo,monospace}
header{padding:12px 16px;border-bottom:1px solid #2c2b27;display:flex;gap:16px;align-items:baseline}
header b{font-weight:600;letter-spacing:.08em}header span{color:#8a877e}
main{display:grid;grid-template-columns:1fr 1fr;height:calc(100vh - 45px)}
section{overflow:auto;padding:8px 12px;border-right:1px solid #2c2b27}
h2{font-size:11px;letter-spacing:.1em;color:#8a877e;margin:8px 0}
.e{display:grid;grid-template-columns:70px 92px 1fr;gap:10px;padding:5px 0;border-bottom:1px dashed #2c2b27;align-items:baseline}
.t{color:#8a877e}.k{font-weight:600}.hearing .k{color:#8a877e}.listening .k{color:#6f8f78}.addressed .k{color:#f3f1e9}
.speaking .k{color:#c9a75a}.stage .k{color:#7fb08a}.tool .k{color:#8fb7d8}.error .k{color:#d86f6f}.earcon .k{color:#a58bd8}
.bar{display:inline-block;height:6px;background:#3d7048;vertical-align:middle;margin-right:6px;border-radius:3px}
.x{color:#c9c6bd}.l{padding:3px 0;border-bottom:1px dashed #2c2b27;white-space:pre-wrap}.l.speak{color:#f3f1e9}.l.err{color:#d86f6f}
</style></head><body>
<header><b>TRANQUILITY · EVENTS</b><span id="s">connecting…</span></header>
<main><section><h2>events.jsonl</h2><div id="ev"></div></section><section><h2>bot.log · gate verdicts and tools</h2><div id="lg"></div></section></main>
<script>
const ev=document.getElementById('ev'),lg=document.getElementById('lg'),s=document.getElementById('s');
function ts(t){const d=new Date(t*1000);return d.toTimeString().slice(0,8)+'.'+String(d.getMilliseconds()).padStart(3,'0').slice(0,1)}
const es=new EventSource('/stream');
es.onopen=()=>s.textContent='live';es.onerror=()=>s.textContent='reconnecting…';
es.addEventListener('event',m=>{const e=JSON.parse(m.data);const d=document.createElement('div');d.className='e '+e.event;
 let x='';if(e.p!==undefined&&e.p!==null)x+='<span class="bar" style="width:'+Math.round(e.p*80)+'px"></span>'+e.p.toFixed(2)+' ';
 if(e.intent)x+='<b>'+e.intent+'</b> ';if(e.ms)x+='<span class="t">'+e.ms+'ms</span> ';if(e.text)x+='<span class="x">'+e.text.replace(/</g,'&lt;')+'</span>';
 if(e.goal)x+='<span class="x">'+e.goal+'</span>';if(e.name)x+=e.name;if(e.argv)x+=e.argv.join(' ');if(e.meaning)x+=' → '+e.meaning;if(e.reason)x+='<span class="x">'+e.reason+'</span>';if(e.voice)x+=' ['+e.voice+']';
 d.innerHTML='<span class="t">'+ts(e.t)+'</span><span class="k">'+e.event+'</span><span>'+x+'</span>';ev.append(d);while(ev.children.length>300)ev.firstChild.remove();ev.parentElement.scrollTop=ev.parentElement.scrollHeight;});
es.addEventListener('log',m=>{const o=JSON.parse(m.data);const d=document.createElement('div');d.className='l'+(o.line.includes('SPEAK')?' speak':'')+(o.level==='ERROR'?' err':'');
 d.textContent=o.time.slice(11,23)+'  '+o.line;lg.append(d);while(lg.children.length>300)lg.firstChild.remove();lg.parentElement.scrollTop=lg.parentElement.scrollHeight;});
</script></body></html>"""


def follow(path, start_at_end=True):
    pos = os.path.getsize(path) if start_at_end and os.path.exists(path) else 0
    while True:
        if os.path.exists(path):
            with open(path, "r", errors="replace") as f:
                f.seek(pos)
                for line in f:
                    yield line.rstrip("\n")
                pos = f.tell()
        yield None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/":
            body = PAGE.encode()
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body); return
        if self.path != "/stream":
            self.send_response(404); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache"); self.end_headers()
        # replay the last 40 events, then follow both files
        try:
            with open(EVENTS, errors="replace") as f:
                for line in f.readlines()[-40:]:
                    self._send("event", line.strip())
        except FileNotFoundError:
            pass
        ev, lg = follow(EVENTS), follow(LOG)
        try:
            while True:
                idle = True
                for line in ev:
                    if line is None: break
                    idle = False; self._send("event", line)
                for line in lg:
                    if line is None: break
                    m = GATE.match(line)
                    if m:
                        idle = False
                        self._send("log", json.dumps({"time": m.group(1), "level": m.group(2), "line": m.group(3)}))
                if idle:
                    self.wfile.write(b": keepalive\n\n"); self.wfile.flush(); time.sleep(0.3)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _send(self, kind, data):
        self.wfile.write(f"event: {kind}\ndata: {data}\n\n".encode()); self.wfile.flush()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(f"events at http://localhost:{PORT}")
    Server(("127.0.0.1", PORT), Handler).serve_forever()
