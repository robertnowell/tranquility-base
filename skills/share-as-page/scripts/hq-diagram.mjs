#!/usr/bin/env node
// hq-diagram: a report diagram in house style, and the draw test that decides
// whether it should exist. Ruled 5 Oct 2026 (hf-eit).
//
//   hq-diagram in.dot > out.svg            inline SVG for the page
//   hq-diagram in.dot --png look.png       also a picture to look at before shipping
//
// Write plain Graphviz dot. House fonts and colours are injected. Mark the one
// node or edge that matters with tone=accent, a broken part with tone=warn.
// Label every edge with what it carries or causes.
//
// The draw test, on stderr: a diagram earns its space only when the reader
// must trace connections. It must be one connected graph, with a branch, a
// merge or a loop, no more than 15 boxes, and labels at 12px or more in a
// 700px column. Otherwise it says which of a sentence, a list or a table
// carries the claim instead, and exits 2. Calibrated on ten replayed report
// claims: it accounted for all ten verdicts.
import { createRequire } from "node:module";
import { readFileSync, existsSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

// Dependencies live in a cache outside the rules store, installed on first use,
// so the store stays plain files and every Mac gets the same versions.
const CACHE = join(homedir(), "Library", "Caches", "tranquility-base", "hq-diagram");
const DEPS = { "@hpcc-js/wasm-graphviz": "1.21.0", "playwright": "1.63.0" };
async function dep(name) {
  const req = createRequire(join(CACHE, "package.json"));
  try { return await import(pathToFileURL(req.resolve(name)).href); } catch {}
  mkdirSync(CACHE, { recursive: true });
  if (!existsSync(join(CACHE, "package.json"))) execFileSync("npm", ["init", "-y"], { cwd: CACHE, stdio: "ignore" });
  process.stderr.write(`installing ${name} into ${CACHE} (once)\n`);
  execFileSync("npm", ["i", "--no-audit", "--no-fund", `${name}@${DEPS[name]}`], { cwd: CACHE, stdio: "ignore" });
  return await import(pathToFileURL(createRequire(join(CACHE, "package.json")).resolve(name)).href);
}

const args = process.argv.slice(2);
const pngAt = args.indexOf("--png"); const png = pngAt >= 0 ? args.splice(pngAt, 2)[1] : null;
if (args[0] === "-h" || args[0] === "--help") { process.stdout.write(readFileSync(new URL(import.meta.url)).toString().split("\nimport")[0] + "\n"); process.exit(0); }
const src = args[0] ? readFileSync(args[0], "utf8") : readFileSync(0, "utf8");

const INK = "#1f1e1c", MUTED = "#57534c", LINE = "#c9c4b8", ACC = "#4a5a2b", WARN = "#a8762a", BG = "#fcfbf8", F = "Helvetica";
const house = `bgcolor="transparent"; pad=0.12; nodesep=0.35; ranksep=0.55; fontname="${F}";
 node [shape=box, style="rounded,filled", fillcolor="${BG}", color="${LINE}", fontname="${F}", fontsize=12, fontcolor="${INK}", margin="0.14,0.08"];
 edge [fontname="${F}", fontsize=11, fontcolor="${MUTED}", color="${MUTED}", arrowsize=0.7];`;
const dot = src.replace(/\{/, "{\n " + house + "\n")
  .replace(/tone\s*=\s*"?accent"?/g, `color="${ACC}", penwidth=1.6, fontcolor="${INK}"`)
  .replace(/tone\s*=\s*"?warn"?/g, `color="${WARN}", penwidth=1.6, fontcolor="${INK}"`);

const gvm = await dep("@hpcc-js/wasm-graphviz"); const Graphviz = gvm.Graphviz ?? gvm.default.Graphviz;
const gv = await Graphviz.load();
let svg = gv.dot(dot).replace(/<\?xml[^>]*>\s*/, "").replace(/<!DOCTYPE[^>]*>\s*/, "").replace(/<!--[\s\S]*?-->\s*/g, "");
// One viewBox unit is one CSS pixel: natural size in the column, shrinking only
// when wider than it. That is the size the draw test's label check assumes.
const natural = +(svg.match(/viewBox="[\d.\-]+ [\d.\-]+ ([\d.]+)/) || [])[1];
svg = svg.replace(/<svg width="[^"]*" height="[^"]*"/, `<svg role="img" style="width:${Math.round(natural)}px;max-width:100%;height:auto"`);
process.stdout.write(svg + "\n");

// THE DRAW TEST.
const COL = 700, MIN_PX = 12, MAX_BOXES = 15;
const vw = +(svg.match(/viewBox="[\d.\-]+ [\d.\-]+ ([\d.]+)/) || [])[1];
const nodes = new Set([...svg.matchAll(/<g id="node\d+" class="node">\s*<title>(.*?)<\/title>/g)].map(m => m[1]));
const edges = [...svg.matchAll(/<g id="edge\d+" class="edge">\s*<title>(.*?)<\/title>/g)].map(m => m[1].split(/&#45;&gt;|&#45;&#45;/));
const out = {}, inn = {}, parent = {};
const find = x => (parent[x] ??= x) === x ? x : (parent[x] = find(parent[x]));
for (const [a, b] of edges) { out[a] = (out[a] || 0) + 1; inn[b] = (inn[b] || 0) + 1; parent[find(a)] = find(b); }
const groups = new Set([...nodes].map(find)).size;
const forks = Object.values(out).filter(n => n > 1).length + Object.values(inn).filter(n => n > 1).length;
const px = vw > COL ? 12 * COL / vw : 12;
const why = [];
if (nodes.size < 3) why.push("fewer than 3 boxes: say it in a sentence");
if (groups > 1) why.push(`${groups} unconnected groups: nothing links them, so it is a table`);
if (!forks && groups === 1 && nodes.size >= 3) why.push("a straight line with no branch, merge or loop: a numbered list says it");
if (nodes.size > MAX_BOXES) why.push(`${nodes.size} boxes: past ${MAX_BOXES}; split it`);
if (px < MIN_PX) why.push(`labels render at ${px.toFixed(1)}px in a ${COL}px column (floor ${MIN_PX}): rankdir=TB, shorter labels, or split`);
process.stderr.write(why.length ? `DO NOT SHIP AS DRAWN: ${why.join("; ")}\n`
  : `draw test passes: ${nodes.size} boxes, ${forks} fork${forks === 1 ? "" : "s"}, labels ${px.toFixed(1)}px. It replaces the table or paragraph it restates.\n`);

if (png) {
  const pw = await dep("playwright"); const chromium = pw.chromium ?? pw.default.chromium;
  const b = await chromium.launch().catch(e => { process.stderr.write("no browser for --png: run `npx playwright install chromium-headless-shell` once\n"); throw e; });
  const p = await b.newPage({ deviceScaleFactor: 2, viewport: { width: 820, height: 400 } });
  await p.setContent(`<body style="margin:16px;background:${BG};width:${COL}px">${svg}</body>`);
  await p.locator("svg").first().screenshot({ path: png }); await b.close();
  process.stderr.write(`look at ${png} before it ships\n`);
}
process.exit(why.length ? 2 : 0);
