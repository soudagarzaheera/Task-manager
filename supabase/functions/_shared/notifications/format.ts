// Formatting helpers. Dates are business dates in the organization's time zone
// (default Asia/Kolkata) — never the server's UTC clock.

export const DEFAULT_TIMEZONE = "Asia/Kolkata";

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** "2026-09-30" -> "30 Sep 2026". A DATE is a calendar day: no time zone shift. */
export function fmtDate(value: unknown): string {
  const s = String(value ?? "");
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
  if (!m) return s;
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]));
  return new Intl.DateTimeFormat("en-IN", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" })
    .format(d);
}

/** A timestamp shown as local date + time in the organization's zone. */
export function fmtDateTime(value: unknown, timeZone = DEFAULT_TIMEZONE): string {
  const d = new Date(String(value ?? ""));
  if (isNaN(d.getTime())) return "";
  return new Intl.DateTimeFormat("en-IN", {
    day: "numeric", month: "short", year: "numeric", hour: "numeric", minute: "2-digit",
    hour12: true, timeZone,
  }).format(d);
}

export function fmtDateRange(from: unknown, to: unknown): string {
  const a = fmtDate(from), b = fmtDate(to);
  return !b || a === b ? a : `${a} – ${b}`;
}

export function fmtHours(value: unknown): string {
  const n = Number(value);
  if (!isFinite(n)) return "";
  return `${Number(n.toFixed(2))}h`;
}

export function fmtDays(value: unknown): string {
  const n = Number(value);
  if (!isFinite(n)) return "";
  return `${Number(n.toFixed(1))} day${n === 1 ? "" : "s"}`;
}

const STATUS_LABELS: Record<string, string> = {
  todo: "To do",
  in_progress: "In progress",
  blocked_on_client: "Blocked on client",
  submitted_for_review: "Submitted for review",
  changes_requested: "Changes requested",
  completed: "Done",
  pending: "Pending",
  approved: "Approved",
  rejected: "Rejected",
  queried: "Sent back",
};
export const statusLabel = (s: unknown) => STATUS_LABELS[String(s)] || String(s ?? "");

const ROLE_LABELS: Record<string, string> = {
  partner: "Partner", manager: "Manager", assistant_manager: "Assistant Manager",
  senior_executive: "Senior Executive", senior_associate: "Senior Associate",
  associate: "Associate", trainee: "Trainee", accounts: "Accounts", admin: "Admin",
  senior: "Senior", article: "Article",   // pre-030 values, kept for queued emails
};
export const roleLabel = (r: unknown) => ROLE_LABELS[String(r)] || String(r ?? "");

export function truncate(value: unknown, max: number): string {
  const s = String(value ?? "").trim();
  return s.length > max ? s.slice(0, max - 1).trimEnd() + "…" : s;
}
