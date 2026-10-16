import type { EngineInterface, Register } from "claude-code";
import { describe, excerpt } from "./text.ts";

// The mascot itself lives in Hammerspoon (~/.hammerspoon/mascota.lua). This plugin drops one JSON
// request per event in its inbox; Hammerspoon picks it up by deleting the file. For an approval or
// a question the script then waits for Hammerspoon's answer file, so the hook waits without
// spending its budget. A reply typed in the bubble comes back as replies/<session>.reply.
const SCRIPT = `
d="$HOME/Library/Caches/mascota"; f="$d/$1"; mkdir -p "$d"
printf '%s' "$2" > "$f.tmp" && mv "$f.tmp" "$f.json"
i=0; while [ -f "$f.json" ] && [ $i -lt 15 ]; do sleep 0.2; i=$((i+1)); done
if [ -f "$f.json" ]; then rm -f "$f.json"; echo off; exit 0; fi
[ "$3" = 1 ] || exit 0
i=0; while [ ! -f "$f.answer" ] && [ $i -lt 1160 ]; do sleep 0.5; i=$((i+1)); done
[ -f "$f.answer" ] && cat "$f.answer" && rm -f "$f.answer"
`;

// A reload starts a new id: Hammerspoon learns the window again at the next prompt.
const session = crypto.randomUUID();
let count = 0;
let label: string | undefined; // the project folder, for the bubble
const ASKING_MODES = new Set(["default", "acceptEdits", "plan"]);
let mode: string | undefined;
let lastAsk: { tool: string; detail: string } | undefined;

async function send($: EngineInterface, kind: string, fields: object, wait = false): Promise<string> {
  const id = `${session}-${++count}`;
  label ??= (await $.session.cwd()).split("/").pop() ?? "";
  const request = JSON.stringify({ kind, session, id, label, wait, ...fields });
  const run = await $.process.run(["/bin/sh", "-c", SCRIPT, "mascota", id, request, wait ? "1" : "0"], {
    timeoutMs: 600_000,
  });
  return run.stdout.trim();
}

let home: string | undefined;

async function pollReply($: EngineInterface): Promise<void> {
  home ??= (await $.process.run(["/bin/sh", "-c", 'printf %s "$HOME"'])).stdout;
  const file = `${home}/Library/Caches/mascota/replies/${session}.reply`;
  if (!(await $.fs.exists(file))) return;
  const run = await $.process.run(["/bin/sh", "-c", 'cat "$1" && rm -f "$1"', "mascota", file]);
  const text = run.stdout.trim();
  if (text) await $.prompt.submit({ text, asUser: true });
}

export const register: Register = (on) => {
  on("session.start", ($, e, next) => {
    $.clock.every(1500, () => pollReply($));
    return next(e);
  });

  on("session.end", ($, e, next) => {
    send($, "end", {}).catch(() => {});
    return next(e);
  });

  // You just pressed Enter in this session's window: Hammerspoon remembers which window that is.
  // A reply sent from the bubble is the plugin's own prompt: the window you are in is not this one.
  on("prompt.submit", ($, e, next) => {
    if (!e.isMeta && e.origin?.kind !== "plugin") send($, "bind", {}).catch(() => {});
    return next(e);
  });

  on("turn.start", ($, e, next) => {
    if (e.agentId === undefined) send($, "working", {}).catch(() => {});
    return next(e);
  });

  on("turn.complete", async ($, e, next) => {
    const result = await next(e);
    if (e.agentId === undefined && e.reason === "answer") {
      send($, "done", { text: excerpt(e.answer), seconds: Math.round(e.durationMs / 1000), mode }).catch(() => {});
    }
    return result;
  });

  // The bubble shows the question and its options; an answer from it fills the tool's `answers`,
  // as the terminal dialog would. "terminal" or no answer leave the dialog to you.
  on("tool.call", { tool: "AskUserQuestion" }, async ($, e, next) => {
    const questions = e.questions.map((q) => ({
      question: q.question,
      header: q.header,
      multiSelect: q.multiSelect,
      options: q.options.map((o) => ({ label: o.label, description: o.description })),
    }));
    const answer = await send($, "question", { questions }, true).catch(() => "");
    if (!answer.startsWith("{")) return next(e);
    return next({ ...e, answers: JSON.parse(answer) });
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
