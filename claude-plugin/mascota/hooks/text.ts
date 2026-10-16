// The short texts the mascot shows: kept pure so the tests can read them.

const MAX = 160;

export function clip(text: string, max = MAX): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > max ? flat.slice(0, max - 1) + "…" : flat;
}

export function firstLine(answer: string): string {
  const line = answer.split("\n").map((l) => l.replace(/^[#>*\-\s]+/, "").trim()).find(Boolean);
  return clip(line ?? "");
}

// What the tool is about to do, in one line: the command, the file, or the arguments.
export function describe(tool: string, input: unknown): string {
  const i = (input ?? {}) as Record<string, unknown>;
  const pick = i.command ?? i.file_path ?? i.notebook_path ?? i.url ?? i.pattern ?? i.path;
  if (typeof pick === "string") return clip(pick);
  try {
    return clip(JSON.stringify(input));
  } catch {
    return tool;
  }
}
