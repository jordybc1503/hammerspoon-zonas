import type { EngineInterface, Register } from "claude-code";
import { describe, firstLine } from "./text.ts";

// The mascot itself lives in Hammerspoon (~/.hammerspoon/mascota.lua). This mod drops one JSON
// request per event in its inbox; Hammerspoon picks it up by deleting the file. For an approval
// the script then waits for Hammerspoon's answer file, so the hook waits without spending its budget.
const SCRIPT = `
d="$HOME/Library/Caches/mascota"; f="$d/$1"; mkdir -p "$d"
printf '%s' "$2" > "$f.tmp" && mv "$f.tmp" "$f.json"
i=0; while [ -f "$f.json" ] && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
if [ -f "$f.json" ]; then rm -f "$f.json"; echo off; exit 0; fi
[ "$3" = 1 ] || exit 0
i=0; while [ ! -f "$f.answer" ] && [ $i -lt 2900 ]; do sleep 0.2; i=$((i+1)); done
[ -f "$f.answer" ] && cat "$f.answer" && rm -f "$f.answer"
`;

// A reload starts a new id: Hammerspoon learns the window again at the next prompt.
const session = crypto.randomUUID();
let count = 0;
const ASKING_MODES = new Set(["default", "acceptEdits", "plan"]);
let mode: string | undefined;
let lastAsk: { tool: string; detail: string } | undefined;

async function send($: EngineInterface, kind: string, fields: object, wait = false): Promise<string> {
  const id = `${session}-${++count}`;
  const label = (await $.session.cwd()).split("/").pop() ?? "";
  const request = JSON.stringify({ kind, session, id, label, ...fields });
  const run = await $.process.run(["/bin/sh", "-c", SCRIPT, "mascota", id, request, wait ? "1" : "0"], {
    timeoutMs: 600_000,
  });
  return run.stdout.trim();
}

export const register: Register = (on) => {
  // You just pressed Enter in this session's window: Hammerspoon remembers which window that is.
  on("prompt.submit", ($, e, next) => {
    if (!e.isMeta) send($, "bind", {}).catch(() => {});
    return next(e);
  });

  on("turn.complete", async ($, e, next) => {
    const result = await next(e);
    if (e.agentId === undefined && e.reason === "answer") {
      send($, "done", { text: firstLine(e.answer), seconds: Math.round(e.durationMs / 1000), mode }).catch(() => {});
    }
    return result;
  });

  on("tool.call", { tool: "AskUserQuestion" }, ($, e, next) => {
    send($, "question", {}).catch(() => {});
    return next(e);
  });

  on("classic.UserPromptSubmit", ($, e, next) => {
    mode = e.permission_mode;
    return next(e);
  });

  // An "ask" only reaches you in these modes. In auto mode the classifier settles most asks after
  // this hook, so the mascot waits for the real prompt (the Notification below) instead.
  on("tool.check", async ($, e, next) => {
    const verdict = await next(e);
    if (verdict.decision !== "ask" || e.tool_use_id === undefined) return verdict;
    lastAsk = { tool: e.tool, detail: describe(e.tool, e.input) };
    if (!ASKING_MODES.has(mode ?? "")) return verdict;
    // "terminal" (you went to the window), "off" (Hammerspoon is not running) or no answer leave the normal prompt.
    const answer = await send($, "ask", lastAsk, true).catch(() => "");
    if (answer === "allow") return { decision: "allow", reason: "Approved from the mascot" };
    if (answer === "deny") return { decision: "deny", reason: "The user denied this from the mascot pop-up." };
    return verdict;
  });

  // Claude Code is showing you a permission prompt now: the mascot points you to it.
  on("classic.Notification", ($, e, next) => {
    mode = e.permission_mode ?? mode;
    if (e.notification_type === "permission_prompt") {
      send($, "needs", lastAsk ?? { detail: e.message }).catch(() => {});
    }
    return next(e);
  });
};
