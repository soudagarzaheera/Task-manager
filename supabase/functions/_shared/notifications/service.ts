// sendNotificationEmail(): the single entry point that every application
// notification goes through. It
//   1. resolves and validates recipients (same organization only),
//   2. builds the template,
//   3. sends through Resend with an idempotency key,
//   4. classifies failures as retryable or permanent,
// and never throws. It does not write to the database — the caller records
// the outcome on the email_notifications row.

import { notificationConfig } from "./config.ts";
import { renderHtml, renderText } from "./layout.ts";
import { sendViaResend } from "./resend.ts";
import { buildEmailContent, isNotificationType, type TemplateData } from "./templates.ts";

// Minimal structural type for the supabase-js service-role client.
type RpcClient = {
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string } | null }>;
};

export type NotificationRequest = {
  /** Stable id of the queued notification — also the Resend idempotency key. */
  id: string;
  organizationId: string;
  type: string;
  toProfileIds: string[];
  ccProfileIds?: string[];
  data: TemplateData;
  /** Optional subject override; normally the template's subject is used. */
  subject?: string | null;
};

export type NotificationOutcome =
  | { status: "sent"; providerMessageId: string; subject: string; to: string[]; cc: string[] }
  | { status: "dry_run"; subject: string; to: string[]; cc: string[]; html: string; text: string }
  | { status: "skipped"; reason: string; subject?: string }
  | { status: "retry" | "failed"; error: string; subject?: string; to?: string[]; cc?: string[] };

type Recipient = { profile_id: string; full_name: string; email: string | null; is_active: boolean };

const EMAIL_RE = /^[^\s@<>(),;:"]+@[^\s@<>(),;:"]+\.[^\s@<>(),;:"]+$/;

// Types whose recipient may already be inactive (telling someone their own
// account was deactivated).
const ALLOW_INACTIVE = new Set(["employee_deactivated"]);

/**
 * Hook for future per-user email preferences. Today every operational
 * notification defined by the business rules is always sent.
 */
function recipientWantsEmail(_recipient: Recipient, _type: string): boolean {
  return true;
}

async function resolveRecipients(
  db: RpcClient, organizationId: string, ids: string[], type: string,
): Promise<Recipient[]> {
  if (!ids.length) return [];
  const { data, error } = await db.rpc("notif_recipients", { p_org: organizationId, p_ids: ids });
  if (error) throw new Error(`Could not resolve recipients: ${error.message}`);
  const rows = (data as Recipient[]) || [];
  const byId = new Map(rows.map((r) => [r.profile_id, r]));
  const seen = new Set<string>();
  const out: Recipient[] = [];
  for (const id of ids) {                     // keep the queued order
    const r = byId.get(id);
    if (!r || !r.email) continue;
    const email = r.email.trim().toLowerCase();
    if (email.length > 254 || !EMAIL_RE.test(email) || seen.has(email)) continue;
    if (!r.is_active && !ALLOW_INACTIVE.has(type)) continue;
    if (!recipientWantsEmail(r, type)) continue;
    seen.add(email);
    out.push({ ...r, email });
  }
  return out;
}

export async function sendNotificationEmail(
  db: RpcClient, req: NotificationRequest, opts: { dryRun?: boolean } = {},
): Promise<NotificationOutcome> {
  if (!isNotificationType(req.type)) {
    return { status: "failed", error: `Unknown notification type "${req.type}".` };
  }

  let to: Recipient[], cc: Recipient[];
  try {
    to = await resolveRecipients(db, req.organizationId, req.toProfileIds || [], req.type);
    const toEmails = new Set(to.map((r) => r.email));
    cc = (await resolveRecipients(db, req.organizationId, req.ccProfileIds || [], req.type))
      .filter((r) => !toEmails.has(r.email as string));
  } catch (err) {
    return { status: "retry", error: err instanceof Error ? err.message : String(err) };
  }
  if (!to.length) {
    return { status: "skipped", reason: "No valid recipient email address (missing, invalid, inactive or opted out)." };
  }

  let subject: string, html: string, text: string;
  try {
    const content = buildEmailContent(req.type, req.data || {});
    subject = (req.subject || content.subject).replace(/[\r\n]+/g, " ").slice(0, 250);
    content.subject = subject;
    const ctx = {
      appName: notificationConfig.appName,
      companyName: String(req.data?.company_name || req.data?.organization_name || notificationConfig.appName),
      recipientName: to.length === 1 ? to[0].full_name.split(" ")[0] : undefined,
    };
    html = renderHtml(content, ctx);
    text = renderText(content, ctx);
  } catch (err) {
    return { status: "failed", error: `Template error: ${err instanceof Error ? err.message : String(err)}` };
  }

  const toList = to.map((r) => r.email as string);
  const ccList = cc.map((r) => r.email as string);

  if (opts.dryRun || notificationConfig.dryRun) {
    return { status: "dry_run", subject, to: toList, cc: ccList, html, text };
  }

  const result = await sendViaResend(
    { to: toList, cc: ccList, subject, html, text, tags: [{ name: "type", value: req.type }] },
    `notification-${req.id}`,
  );
  if (result.ok) return { status: "sent", providerMessageId: result.id, subject, to: toList, cc: ccList };
  return { status: result.transient ? "retry" : "failed", error: result.error, subject, to: toList, cc: ccList };
}
