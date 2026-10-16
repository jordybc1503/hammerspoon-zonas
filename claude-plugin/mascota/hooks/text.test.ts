import { expect, test } from "claude-code/testing";
import { clip, describe, firstLine } from "./text.ts";

test("firstLine skips blank lines and markdown marks", () => {
  expect(firstLine("\n\n## Done: the tests pass\nmore")).toBe("Done: the tests pass");
});

test("clip shortens long text", () => {
  expect(clip("a".repeat(200), 10)).toBe("aaaaaaaaa…");
});

test("describe shows the command or the file", () => {
  expect(describe("Bash", { command: "git push origin main" })).toBe("git push origin main");
  expect(describe("Edit", { file_path: "/tmp/x.ts", old_string: "a" })).toBe("/tmp/x.ts");
  expect(describe("mcp__x__y", { id: 3 })).toBe('{"id":3}');
});
