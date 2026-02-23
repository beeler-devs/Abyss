export interface DiffLine {
  type: "context" | "add" | "remove";
  text: string;
}

export interface DiffHunk {
  oldStart: number;
  oldCount: number;
  newStart: number;
  newCount: number;
  lines: DiffLine[];
}

export interface FilePatch {
  oldPath: string;
  newPath: string;
  hunks: DiffHunk[];
}

const HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

function normalizePath(path: string): string {
  return path.replace(/^a\//, "").replace(/^b\//, "").trim();
}

export function parseUnifiedDiff(diff: string): FilePatch[] {
  const lines = diff.split(/\r?\n/);
  const files: FilePatch[] = [];

  let i = 0;
  let currentFile: FilePatch | null = null;

  while (i < lines.length) {
    const line = lines[i] ?? "";

    if (line.startsWith("--- ")) {
      const oldPathRaw = line.slice(4).trim();
      const next = lines[i + 1] ?? "";
      if (!next.startsWith("+++ ")) {
        throw new Error(`invalid_diff_missing_new_path_at_line_${i + 2}`);
      }
      const newPathRaw = next.slice(4).trim();

      currentFile = {
        oldPath: normalizePath(oldPathRaw),
        newPath: normalizePath(newPathRaw),
        hunks: [],
      };
      files.push(currentFile);
      i += 2;
      continue;
    }

    const hunkHeaderMatch = line.match(HUNK_HEADER);
    if (hunkHeaderMatch) {
      if (!currentFile) {
        throw new Error(`invalid_diff_hunk_without_file_at_line_${i + 1}`);
      }

      const oldStart = Number.parseInt(hunkHeaderMatch[1] ?? "1", 10);
      const oldCount = Number.parseInt(hunkHeaderMatch[2] ?? "1", 10);
      const newStart = Number.parseInt(hunkHeaderMatch[3] ?? "1", 10);
      const newCount = Number.parseInt(hunkHeaderMatch[4] ?? "1", 10);

      const hunk: DiffHunk = {
        oldStart,
        oldCount,
        newStart,
        newCount,
        lines: [],
      };
      i += 1;

      while (i < lines.length) {
        const hunkLine = lines[i] ?? "";
        if (hunkLine.startsWith("@@ ") || hunkLine.startsWith("--- ")) {
          break;
        }
        if (hunkLine.startsWith("+")) {
          hunk.lines.push({ type: "add", text: hunkLine.slice(1) });
        } else if (hunkLine.startsWith("-")) {
          hunk.lines.push({ type: "remove", text: hunkLine.slice(1) });
        } else if (hunkLine.startsWith(" ")) {
          hunk.lines.push({ type: "context", text: hunkLine.slice(1) });
        } else if (hunkLine.startsWith("\\ No newline at end of file")) {
          // Ignore marker.
        } else if (hunkLine.length === 0) {
          hunk.lines.push({ type: "context", text: "" });
        } else {
          throw new Error(`invalid_hunk_line_at_${i + 1}`);
        }
        i += 1;
      }

      currentFile.hunks.push(hunk);
      continue;
    }

    i += 1;
  }

  return files;
}

export function applyPatchToText(baseContent: string, filePatch: FilePatch): string {
  const sourceLines = baseContent.split(/\r?\n/);
  const outputLines: string[] = [];

  let sourceIndex = 0;

  for (const hunk of filePatch.hunks) {
    const hunkStart = Math.max(0, hunk.oldStart - 1);

    while (sourceIndex < hunkStart && sourceIndex < sourceLines.length) {
      outputLines.push(sourceLines[sourceIndex] ?? "");
      sourceIndex += 1;
    }

    for (const line of hunk.lines) {
      if (line.type === "context") {
        const current = sourceLines[sourceIndex] ?? "";
        if (current !== line.text) {
          throw new Error(`context_mismatch:${filePatch.newPath}:${sourceIndex + 1}`);
        }
        outputLines.push(current);
        sourceIndex += 1;
      } else if (line.type === "remove") {
        const current = sourceLines[sourceIndex] ?? "";
        if (current !== line.text) {
          throw new Error(`remove_mismatch:${filePatch.newPath}:${sourceIndex + 1}`);
        }
        sourceIndex += 1;
      } else if (line.type === "add") {
        outputLines.push(line.text);
      }
    }
  }

  while (sourceIndex < sourceLines.length) {
    outputLines.push(sourceLines[sourceIndex] ?? "");
    sourceIndex += 1;
  }

  return outputLines.join("\n");
}

export function diffChangedLineCount(filePatches: FilePatch[]): number {
  let total = 0;
  for (const filePatch of filePatches) {
    for (const hunk of filePatch.hunks) {
      total += hunk.lines.filter((line) => line.type !== "context").length;
    }
  }
  return total;
}

export function whitespaceOnlyChangeCount(filePatches: FilePatch[]): number {
  let total = 0;
  for (const filePatch of filePatches) {
    for (const hunk of filePatch.hunks) {
      for (const line of hunk.lines) {
        if (line.type === "context") {
          continue;
        }
        if (line.text.trim().length === 0) {
          total += 1;
        }
      }
    }
  }
  return total;
}
