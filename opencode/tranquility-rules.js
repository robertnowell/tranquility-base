// Tranquility Base's rules for OpenCode sessions.
//
// OpenCode has no Claude-style hooks, so until 30 Sep 2026 its sessions never
// received the page rules every Claude Code and Codex session gets (where
// pages go, the house template, how they reach the hub). OpenCode auto-loads
// any plugin in ~/.config/opencode/plugins/; the app links this file there
// (SkillManifest.repairOpenCodePlugin) from its rules store.
//
// Nothing is restated here. The text comes from the same session-start hook
// the other harnesses run, fed the app's id for this session, and it is added
// to the system prompt on every message. It is fetched again whenever the
// rules change (the store's fingerprint), so a long-running session picks up
// new rules on its next message rather than never.
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, realpathSync, existsSync } from "node:fs";
import { dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";

// The rules tree to read from: the store's stable `current` when this file
// was loaded out of a staged version, else the tree it sits in (a checkout).
function rulesRoot() {
  const here = dirname(realpathSync(fileURLToPath(import.meta.url)));
  const tree = dirname(here);                         // <tree>/opencode -> <tree>
  const versions = dirname(tree);                     // <root>/versions/<fp>
  if (versions.endsWith(sep + "versions")) {
    const current = join(dirname(versions), "current");
    if (existsSync(current)) return current;
  }
  return tree;
}

// The app's id for an OpenCode session: the id itself when it is already hex
// and dashes (ArtifactStore.isPlausibleSession), else sha256("opencode\0" + id)
// in hex, exactly as AgentSession.id computes it. The agent's folder and hub
// page are named by this id, so it must match byte for byte.
export function appSessionId(raw) {
  if (/^[0-9a-f-]{1,64}$/i.test(raw)) return raw;
  return createHash("sha256").update("opencode\u0000" + raw).digest("hex");
}

function fingerprint(root) {
  try { return readFileSync(join(root, ".fingerprint"), "utf8").trim(); } catch { return "checkout"; }
}

function rulesFor(root, sessionId) {
  const hook = join(root, "hooks", "visual-output-hook.sh");
  if (!existsSync(hook)) return "";
  const run = spawnSync("/bin/bash", [hook], {
    input: JSON.stringify({ session_id: sessionId, hook_event_name: "SessionStart", source: "startup" }),
    encoding: "utf8", timeout: 15000,
  });
  try { return JSON.parse(run.stdout).hookSpecificOutput?.additionalContext || ""; } catch { return ""; }
}

export const TranquilityRules = async () => {
  const cache = new Map();   // opencode session id -> { print, text }
  return {
    "experimental.chat.system.transform": async (input, output) => {
      const raw = input?.sessionID;
      if (!raw) return;
      const root = rulesRoot();
      const print = fingerprint(root);
      let hit = cache.get(raw);
      if (!hit || hit.print !== print) {
        hit = { print, text: rulesFor(root, appSessionId(raw)) };
        cache.set(raw, hit);
      }
      if (hit.text) output.system.push(hit.text);
    },
  };
};
