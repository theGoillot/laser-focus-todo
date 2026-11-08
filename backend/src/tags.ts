import { OpError, isDay } from "./types";

const TAG = /(?<=^|[^\p{L}\p{N}_#&/])#([\p{L}\p{N}_][\p{L}\p{N}_.\-/]*)/gu;

/** Workflowy-style inline tags: `#acme.io`, `#work`. Lowercased, unique, in order. Trailing punctuation is not part of a tag. */
export function tagsIn(text: string): string[] {
  const out: string[] = [];
  for (const m of text.matchAll(TAG)) {
    const t = m[1].replace(/[.\-/]+$/, "").toLowerCase();
    if (t && !out.includes(t)) out.push(t);
  }
  return out;
}

/** The calendar day (YYYY-MM-DD) at `at` in time zone `tz`. */
export function localDay(at: Date, tz: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(at);
}

export function addDays(day: string, n: number): string {
  return new Date(Date.parse(day + "T12:00:00Z") + n * 864e5).toISOString().slice(0, 10);
}

/** Agent date input: "today", "tomorrow" or YYYY-MM-DD; null clears. Anything else is refused, never dropped. */
export function resolveDay(input: string | null | undefined, tz: string, field: string): string | null | undefined {
  if (input === undefined) return undefined;
  if (input === null || input === "") return null;
  const v = input.trim().toLowerCase();
  const today = localDay(new Date(), tz);
  if (v === "today") return today;
  if (v === "tomorrow") return addDays(today, 1);
  if (isDay(v)) return v;
  throw new OpError("BAD_DATE", `${field} must be "today", "tomorrow", a YYYY-MM-DD day, or null to clear (got "${input}")`);
}
