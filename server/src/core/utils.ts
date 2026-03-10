/**
 * Safely narrow an unknown value to a plain object (non-array).
 */
export function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return undefined;
  }
  return value as Record<string, unknown>;
}

/**
 * Return a trimmed non-empty string from an unknown value, or undefined.
 */
export function optionalString(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/**
 * Look up the first non-empty string value for any of the given keys in a record.
 */
export function stringFromRecord(record: Record<string, unknown>, ...keys: string[]): string | undefined {
  for (const key of keys) {
    const value = record[key];
    if (typeof value === "string") {
      const trimmed = value.trim();
      if (trimmed.length) {
        return trimmed;
      }
    }
  }
  return undefined;
}

/**
 * Collapse whitespace and truncate a value for log output.
 */
export function summarizeValueForLog(value: unknown, maxLen = 80): string | null {
  let text: string;
  if (typeof value === "string") {
    text = value;
  } else {
    const json = JSON.stringify(value);
    if (!json) {
      return null;
    }
    text = json;
  }

  const normalized = text.replace(/\s+/g, " ").trim();
  if (!normalized) {
    return null;
  }

  if (normalized.length <= maxLen) {
    return normalized;
  }

  return `${normalized.slice(0, maxLen - 1)}…`;
}
