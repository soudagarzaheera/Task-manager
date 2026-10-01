// One responsive HTML layout (plus a plain-text twin) shared by every
// notification. Table-based with inline styles so it renders in Gmail,
// Outlook and mobile clients. All dynamic text is escaped here.

import { escapeHtml as esc } from "./format.ts";

export type Tone = "info" | "ok" | "warn" | "bad";

export type EmailTable = {
  heading: string;
  columns: string[];
  rows: string[][];
  /** How many further rows exist beyond those listed. */
  more?: number;
};

export type EmailContent = {
  subject: string;
  /** Inbox preview line. */
  preheader: string;
  title: string;
  /** Short summary paragraph. */
  intro: string;
  /** Label/value pairs; empty values are dropped. */
  details: [string, string | null | undefined][];
  tables?: EmailTable[];
  /** A quoted block such as a reason or instruction. */
  note?: { label: string; text: string } | null;
  /** Button — omitted automatically when the link is null (no APP_BASE_URL). */
  action?: { label: string; url: string | null } | null;
  tone?: Tone;
};

export type RenderContext = {
  appName: string;
  companyName: string;
  recipientName?: string;
};

const TONE_COLOR: Record<Tone, string> = {
  info: "#2457c5",
  ok: "#1f7a44",
  warn: "#a15c00",
  bad: "#b42318",
};

export function renderHtml(c: EmailContent, ctx: RenderContext): string {
  const accent = TONE_COLOR[c.tone || "info"];
  const details = c.details.filter(([, v]) => v !== null && v !== undefined && String(v).trim() !== "");

  const detailRows = details.map(([label, value]) =>
    `<tr>
      <td style="padding:6px 12px 6px 0;color:#667085;font-size:13px;vertical-align:top;white-space:nowrap">${esc(label)}</td>
      <td style="padding:6px 0;color:#101828;font-size:14px;vertical-align:top;word-break:break-word">${esc(value)}</td>
    </tr>`).join("");

  const tables = (c.tables || []).filter((t) => t.rows.length).map((t) =>
    `<tr><td style="padding:18px 0 0">
      <div style="font-size:13px;font-weight:600;color:#101828;margin:0 0 6px">${esc(t.heading)}</div>
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px">
        <tr>${t.columns.map((h) =>
          `<th align="left" style="padding:6px 8px;border-bottom:1px solid #e4e7ec;color:#667085;font-weight:600">${esc(h)}</th>`).join("")}</tr>
        ${t.rows.map((r) => `<tr>${r.map((cell) =>
          `<td style="padding:6px 8px;border-bottom:1px solid #f2f4f7;color:#101828;vertical-align:top;word-break:break-word">${esc(cell)}</td>`).join("")}</tr>`).join("")}
      </table>
      ${t.more ? `<div style="font-size:12px;color:#667085;padding:6px 8px">and ${t.more} more…</div>` : ""}
    </td></tr>`).join("");

  const note = c.note && c.note.text.trim()
    ? `<tr><td style="padding:16px 0 0">
        <div style="font-size:12px;color:#667085;margin:0 0 4px">${esc(c.note.label)}</div>
        <div style="border-left:3px solid ${accent};background:#f9fafb;padding:10px 12px;font-size:14px;color:#101828;white-space:pre-wrap;word-break:break-word">${esc(c.note.text)}</div>
      </td></tr>`
    : "";

  const button = c.action && c.action.url
    ? `<tr><td style="padding:24px 0 4px">
        <a href="${esc(c.action.url)}" style="display:inline-block;background:${accent};color:#ffffff;text-decoration:none;font-weight:600;font-size:14px;padding:11px 20px;border-radius:6px">${esc(c.action.label)}</a>
      </td></tr>`
    : "";

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light">
<title>${esc(c.subject)}</title>
</head>
<body style="margin:0;padding:0;background:#f2f4f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
<div style="display:none;max-height:0;overflow:hidden;opacity:0">${esc(c.preheader)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f4f7">
  <tr><td align="center" style="padding:24px 12px">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px;background:#ffffff;border-radius:8px;border-top:4px solid ${accent}">
      <tr><td style="padding:20px 24px 0">
        <div style="font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#667085">${esc(ctx.companyName)} · ${esc(ctx.appName)}</div>
      </td></tr>
      <tr><td style="padding:8px 24px 0">
        <h1 style="margin:0;font-size:20px;line-height:1.3;color:#101828">${esc(c.title)}</h1>
      </td></tr>
      <tr><td style="padding:10px 24px 0;font-size:14px;line-height:1.55;color:#344054">
        ${ctx.recipientName ? `<p style="margin:0 0 8px">Hi ${esc(ctx.recipientName)},</p>` : ""}
        <p style="margin:0">${esc(c.intro)}</p>
      </td></tr>
      <tr><td style="padding:0 24px 24px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
          ${details.length ? `<tr><td style="padding:16px 0 0"><table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse">${detailRows}</table></td></tr>` : ""}
          ${note}
          ${tables}
          ${button}
        </table>
      </td></tr>
    </table>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px">
      <tr><td style="padding:14px 24px;font-size:12px;line-height:1.5;color:#98a2b3;text-align:center">
        Automated notification from ${esc(ctx.appName)} for ${esc(ctx.companyName)}.<br>
        You received this because of your role on this item. Please do not reply to this email.
      </td></tr>
    </table>
  </td></tr>
</table>
</body>
</html>`;
}

export function renderText(c: EmailContent, ctx: RenderContext): string {
  const lines: string[] = [];
  lines.push(`${ctx.companyName} · ${ctx.appName}`, "", c.title, "");
  if (ctx.recipientName) lines.push(`Hi ${ctx.recipientName},`, "");
  lines.push(c.intro, "");
  for (const [label, value] of c.details) {
    if (value !== null && value !== undefined && String(value).trim() !== "") lines.push(`${label}: ${value}`);
  }
  if (c.note && c.note.text.trim()) lines.push("", `${c.note.label}:`, c.note.text);
  for (const t of c.tables || []) {
    if (!t.rows.length) continue;
    lines.push("", `${t.heading}:`);
    for (const r of t.rows) lines.push(`- ${r.filter(Boolean).join(" | ")}`);
    if (t.more) lines.push(`  and ${t.more} more…`);
  }
  if (c.action && c.action.url) lines.push("", `${c.action.label}: ${c.action.url}`);
  lines.push("", "—", `Automated notification from ${ctx.appName} for ${ctx.companyName}. Please do not reply.`);
  return lines.join("\n");
}
