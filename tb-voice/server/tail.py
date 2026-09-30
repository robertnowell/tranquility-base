"""A browser view of the manager's event stream: http://localhost:7861

Tails the event stream the app keeps and streams it to the page over
Server-Sent Events, in four columns: who said what, the events, every model
call in full, and the gate's verdicts. Stdlib only; run with `python3 tail.py`
from this directory or `./tail.sh`.
"""

import http.server
import json
import os
import socketserver
import time

# The stream the app writes as it receives it (EventsLog.swift): every event
# line, every `said` line, every model call and every gate verdict (hf-14).
EVENTS = os.getenv("TB_EVENTS_FILE") or os.path.expanduser(
    "~/Library/Application Support/VoiceDispatch/manager-events.jsonl")
PORT = int(os.getenv("TB_TAIL_PORT", "7861"))

PAGE = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>Tranquility · events</title>
<style>
:root{color-scheme:dark}body{margin:0;background:#141412;color:#e8e6df;font:13px/1.45 ui-monospace,Menlo,monospace}
header{padding:12px 16px;border-bottom:1px solid #2c2b27;display:flex;gap:16px;align-items:baseline}
header b{font-weight:600;letter-spacing:.08em}header span{color:#8a877e}
main{display:grid;grid-template-columns:1fr 1fr 1fr;height:calc(100vh - 45px)}
.c{padding:6px 0;border-bottom:1px dashed #2c2b27}.c .h{cursor:pointer}.c .h b{color:#6d8fb5}.c.jev .h b{color:#6d8fb5}.c.brain .h b{color:#c9a75a}.c.llm .h b{color:#8fb7d8}
.c pre{display:none;margin:4px 0 0;font-size:11px;color:#b9b6ad;white-space:pre-wrap;word-break:break-word;max-height:70vh;overflow:auto;background:#1a1a17;padding:8px;border-radius:4px}.c.open pre{display:block}
.tr{padding:3px 0;border-bottom:1px dashed #2c2b27;white-space:pre-wrap}.tr.you{color:#e8e6df}.tr.mgr{color:#c9a75a}.tr.agent{color:#7fb08a}
section{overflow:auto;padding:8px 12px;border-right:1px solid #2c2b27}
h2{font-size:11px;letter-spacing:.1em;color:#8a877e;margin:8px 0}
.e{display:grid;grid-template-columns:70px 92px 1fr;gap:10px;padding:5px 0;border-bottom:1px dashed #2c2b27;align-items:baseline}
.t{color:#8a877e}.k{font-weight:600}.hearing .k{color:#8a877e}.listening .k{color:#6f8f78}.addressed .k{color:#f3f1e9}.jev .k{color:#6d8fb5}
.jev pre{margin:2px 0 0;font-size:11px;color:#9a978e;white-space:pre-wrap;max-height:0;overflow:hidden;transition:max-height .2s}
.jev.open pre{max-height:600px}.jev .sum{cursor:pointer}
.speaking .k{color:#c9a75a}.stage .k{color:#7fb08a}.tool .k{color:#8fb7d8}.error .k{color:#d86f6f}.earcon .k{color:#a58bd8}
.bar{display:inline-block;height:6px;background:#3d7048;vertical-align:middle;margin-right:6px;border-radius:3px}
.x{color:#c9c6bd}.l{padding:3px 0;border-bottom:1px dashed #2c2b27;white-space:pre-wrap}.l.speak{color:#f3f1e9}.l.err{color:#d86f6f}
</style></head><body>
<header><b>TRANQUILITY · EVENTS</b><span id="s">connecting…</span></header>
<main><section><h2>who said what</h2><div id="tr"></div><h2>events</h2><div id="ev"></div></section><section><h2>every model call, full request and response (click)</h2><div id="ca"></div></section><section><h2>gate verdicts and tools</h2><div id="lg"></div></section></main>
<script>
const ev=document.getElementById('ev'),lg=document.getElementById('lg'),s=document.getElementById('s');
function ts(t){const d=new Date(t*1000);return d.toTimeString().slice(0,8)+'.'+String(d.getMilliseconds()).padStart(3,'0').slice(0,1)}
const es=new EventSource('/stream');
es.onopen=()=>s.textContent='live';es.onerror=()=>s.textContent='reconnecting…';
es.addEventListener('event',m=>{const e=JSON.parse(m.data);
 // One row for a whole line being spoken, not one per word.
 //
 // ElevenLabs hands over a whole utterance's alignment with the audio, so
 // every `spoke` arrives in the same tick: sixty-four rows at 12:32:54.3 for
 // one sentence, three times asked about and three times explained instead of
 // fixed. Progress is a bar, not a log. The run collapses into the row it
 // started, which advances in place and shows how far through the line the
 // voice has got.
 if(e.event==='spoke'){const last=ev.lastElementChild;
  if(last&&last.classList.contains('spoke')){const bar=last.querySelector('.prog');
   const n=(+last.dataset.n||1)+1;last.dataset.n=n;
   if(bar&&e.upTo!==undefined){bar.textContent=e.upTo+' chars, '+n+' words'
    +(e.at!==undefined&&e.at!==null?' · '+e.at.toFixed(1)+'s':'');}
   ev.parentElement.scrollTop=ev.parentElement.scrollHeight;return;}
  const d=document.createElement('div');d.className='e spoke';d.dataset.n=1;
  d.innerHTML='<span class="t">'+ts(e.t)+'</span><span class="k">spoke</span>'
   +'<span class="prog t">'+(e.upTo!==undefined?e.upTo+' chars, 1 word':'')+'</span>';
  ev.append(d);while(ev.children.length>300)ev.firstChild.remove();
  ev.parentElement.scrollTop=ev.parentElement.scrollHeight;return;}
 const d=document.createElement('div');d.className='e '+e.event;
 if(e.event==='jev'){const a=e.answers||{};const ad=a.addressed?a.addressed.noul:null;const it=a.intent||{};const top=Object.entries(it.probabilities||{}).sort((x,y)=>y[1]-x[1]).slice(0,3).map(([k,v])=>k+' '+v.toFixed(2)).join(' · ');
  d.innerHTML='<span class="t">'+ts(e.t)+'</span><span class="k">jev</span><span><span class="sum">'+(e.ms||'?')+'ms · addressed '+(ad!==null?ad.toFixed(2):'?')+(e.rule?' → '+e.rule:'')+' · '+top+' <span class="t">(click for the call)</span></span><pre>'+JSON.stringify({state:e.state,answers:e.answers},null,1).replace(/</g,'&lt;')+'</pre></span>';
  d.querySelector('.sum').onclick=()=>d.classList.toggle('open');ev.append(d);while(ev.children.length>300)ev.firstChild.remove();ev.parentElement.scrollTop=ev.parentElement.scrollHeight;return;}
 let x='';if(e.p!==undefined&&e.p!==null){x+='<span class="bar" style="width:'+Math.round(e.p*80)+'px"></span>'+e.p.toFixed(2)+' ';x+=e.event==='addressed'?'<b style="color:#f3f1e9">SPEAK</b> ':'<span class="t">silent</span> ';}
 if(e.intent)x+='<b>'+e.intent+'</b> ';if(e.ms)x+='<span class="t">'+e.ms+'ms</span> ';if(e.text)x+='<span class="x">'+e.text.replace(/</g,'&lt;')+'</span>';
 if(e.goal)x+='<span class="x">'+e.goal+'</span>';if(e.name)x+=e.name;if(e.argv)x+=e.argv.join(' ');if(e.meaning)x+=' → '+e.meaning;if(e.reason)x+='<span class="x">'+e.reason+'</span>';if(e.voice)x+=' ['+e.voice+']';
 d.innerHTML='<span class="t">'+ts(e.t)+'</span><span class="k">'+e.event+'</span><span>'+x+'</span>';ev.append(d);while(ev.children.length>300)ev.firstChild.remove();ev.parentElement.scrollTop=ev.parentElement.scrollHeight;});
const ca=document.getElementById('ca'),tr=document.getElementById('tr');
es.addEventListener('call',m=>{const c=JSON.parse(m.data);const d=document.createElement('div');d.className='c '+c.kind;
 let sum='';try{if(c.kind==='jev'){const a=c.response.answers||{};sum='addressed '+(a.addressed?a.addressed.noul.toFixed(2):'?')+' · '+(a.intent?a.intent.choice+' '+a.intent.confidence.toFixed(2):'')+' · "'+(c.request.state.text_to_judge||c.request.state.utterance||'').slice(0,60)+'"';}
 else if(c.kind==='brain'){sum='"'+(c.request.messages[1].content.split('Question: ').pop()||'').slice(0,60)+'" → '+(c.response.choices[0].message.content||'').slice(0,80);}
 else if(c.kind==='loop'){const msgs=c.request.messages||[];const q=(msgs[1]&&String(msgs[1].content).split('\\n').pop())||'';const m=(c.response.choices||[{}])[0].message||{};sum=msgs.length+' msgs · '+q.slice(0,50)+' → '+((m.tool_calls||[]).length?'tools '+m.tool_calls.map(t=>t.function.name).join(','):'')+' '+String(m.content||'').slice(0,60);}
 else if(c.kind==='llm'){const msgs=c.request.messages||[];const last=msgs[msgs.length-1]||{};sum=msgs.length+' msgs · last '+(last.role||'')+': '+String(last.content||'').slice(0,50)+' → '+(c.response.tool_calls.length?'tools '+c.response.tool_calls.map(t=>t.name).join(','):'')+' '+(c.response.content||'').slice(0,60);}}catch(e){sum='(unparsed)'}
 d.innerHTML='<div class="h"><span class="t">'+ts(c.t)+'</span> <b>'+c.kind+'</b> <span class="t">'+(c.ms||'?')+'ms</span> '+sum.replace(/</g,'&lt;')+'</div><pre>REQUEST\\n'+JSON.stringify(c.request,null,1).replace(/</g,'&lt;')+'\\n\\nRESPONSE\\n'+JSON.stringify(c.response,null,1).replace(/</g,'&lt;')+'</pre>';
 d.querySelector('.h').onclick=()=>d.classList.toggle('open');ca.append(d);while(ca.children.length>200)ca.firstChild.remove();ca.parentElement.scrollTop=ca.parentElement.scrollHeight;});
es.addEventListener('transcript',m=>{const o=JSON.parse(m.data);const d=document.createElement('div');const who=(o.line.split('  ')[1]||'');d.className='tr '+(who.startsWith('you')?'you':who.startsWith('Tranquility')?'mgr':'agent');d.textContent=o.line;tr.append(d);while(tr.children.length>200)tr.firstChild.remove();});
es.addEventListener('log',m=>{const o=JSON.parse(m.data);const d=document.createElement('div');d.className='l'+(o.line.includes('SPEAK')?' speak':'')+(o.level==='ERROR'?' err':'');
 d.textContent=o.time.slice(11,23)+'  '+o.line;lg.append(d);while(lg.children.length>300)lg.firstChild.remove();lg.parentElement.scrollTop=lg.parentElement.scrollHeight;});
</script></body></html>"""


def follow(path, start_at_end=True):
    pos = os.path.getsize(path) if start_at_end and os.path.exists(path) else 0
    while True:
        if os.path.exists(path):
            if os.path.getsize(path) < pos:
                pos = 0  # rotated (EventsLog.swift): start on the new file
            with open(path, errors="replace") as f:
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
        # The calls, verdicts and lines from further back, then the last 40 events in full.
        parts: dict[str, list] = {}
        try:
            with open(EVENTS, errors="replace") as f:
                recent = f.readlines()[-2000:]
        except FileNotFoundError:
            recent = []
        for i, line in enumerate(recent):
            self._event(line.strip(), parts, quiet=i < len(recent) - 40)
        try:
            for line in follow(EVENTS):
                if line is None:
                    self.wfile.write(b": keepalive\n\n"); self.wfile.flush(); time.sleep(0.3)
                    continue
                self._event(line, parts)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _event(self, line, parts, quiet=False):
        """One line of the event stream. A `said` line is the transcript column;
        a model call comes in parts, joined back into the calls column (hf-14);
        a verdict is also the gate column's line. `quiet` replays only those,
        not the whole stream."""
        try:
            e = json.loads(line)
        except ValueError:
            return
        if e.get("event") == "call":
            got = parts.setdefault(e.get("id"), [None] * int(e.get("parts") or 1))
            if 0 <= int(e.get("part", -1)) < len(got):
                got[int(e["part"])] = e.get("text") or ""
            if all(p is not None for p in got):
                parts.pop(e.get("id"), None)
                self._send("call", "".join(got))
            return
        if e.get("event") == "spoke":
            # One per word, for the panel's highlight: the `speaking` line
            # above it already shows the whole sentence (29 Sep: forty rows
            # of "spoke" for one line).
            return
        if e.get("event") == "said":
            who = "you" if e.get("role") == "user" else (e.get("speaker") or "Tranquility")
            self._send("transcript", json.dumps({"line": f"{time.strftime('%H:%M:%S', time.localtime(e.get('t') or 0))}  "
                                                         f"{who}: {e.get('text') or ''}"}))
            return
        if e.get("event") in ("listening", "addressed"):
            verdict = (f"gate p={e.get('p', 0):.2f} {e.get('intent') or ''} {e.get('ms') or '?'}ms "
                       f"{'SPEAK' if e['event'] == 'addressed' else 'silent'} :: {e.get('text') or ''}")
            t = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(e.get("t") or 0)) + f".{int((e.get('t') or 0) % 1 * 1000):03d}"
            self._send("log", json.dumps({"time": t, "level": "INFO", "line": verdict}))
        if not quiet:
            self._send("event", line)

    def _send(self, kind, data):
        self.wfile.write(f"event: {kind}\ndata: {data}\n\n".encode()); self.wfile.flush()


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(f"events at http://localhost:{PORT}")
    Server(("127.0.0.1", PORT), Handler).serve_forever()
