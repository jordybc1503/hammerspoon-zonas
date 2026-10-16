// The short texts the mascot shows: kept pure so the tests can read them.

const MAX = 160;

export function clip(text: string, max = MAX): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length > max ? flat.slice(0, max - 1) + "…" : flat;
}

// The whole answer for the bubble, which scrolls: line breaks kept, cut at `max` characters.
export function excerpt(answer: string, max = 4000): string {
  const text = answer.trim();
  return text.length > max ? text.slice(0, max - 1) + "…" : text;
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
