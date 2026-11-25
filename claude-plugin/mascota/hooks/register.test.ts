import type { On } from "claude-code";
import { expect, mock, test } from "claude-code/testing";

// The engine beneath the plugin; returns what the plugin sends Hammerspoon, by kind (the shell
// script's request is its 6th argument).
function inbox(on: On): string[] {
  const kinds: string[] = [];
  on("session.cwd", () => ({ value: "/work/proj" }));
  on("turn.start", (_, e) => ({ turnId: e.turnId }));
  on("turn.complete", (_, e) => ({ text: e.answer }));
  on("process.run", (_, e) => {
    if (e.argv[5]?.startsWith("{")) kinds.push(JSON.parse(e.argv[5]).kind);
    return { value: { exitCode: 0, stdout: "", stderr: "", isStdoutTruncated: false, isStderrTruncated: false } };
  });
  return kinds;
}

const end = (turnId: string, agentId?: string) =>
  ({ answer: "ok", durationMs: 1000, isAborted: false, reason: "answer", turnId, agentId }) as const;

test("a background agent in flight keeps the session working; its end lets it be done", async ($, on) => {
  const clock = mock.clock(on);
  mock.env(on, {});
  const kinds = inbox(on);

  await $.turn.start({ text: "go", turnId: "m1" });
  await $.turn.start({ text: "dig", turnId: "a1", agentId: "agent-1" });
  await $.turn.complete(end("m1"));
  await clock.advance(3000);
  expect(kinds).toEqual(["working", "working"]);

  // The agent reports back and wakes the main loop, which then ends for good.
  await $.turn.complete(end("a1", "agent-1"));
  await $.turn.start({ text: "", turnId: "m2" });
  await $.turn.complete(end("m2"));
  await clock.advance(3000);
  expect(kinds).toEqual(["working", "working", "working", "done"]);
});

test("with nothing in flight the turn's end is done", async ($, on) => {
  const clock = mock.clock(on);
  mock.env(on, {});
  const kinds = inbox(on);

  await $.turn.start({ text: "go", turnId: "m1" });
  await $.turn.complete(end("m1"));
  await clock.advance(3000);
  expect(kinds).toEqual(["working", "done"]);
});
