// Supabase Edge Function: send-notifications
//
// Server-to-server only. pg_cron calls it every minute through pg_net (see
// notif_invoke_dispatcher() in migrations/026_email_notifications.sql) with
// the shared x-notifications-secret header. It claims queued rows from
// email_notifications, sends each one through sendNotificationEmail(), and
// records the outcome on the same row:
//
//   sent      provider_message_id + sent_at recorded
//   retry     temporary failure (network, 429, 5xx) — retried with backoff
//   failed    permanent failure, or MAX_ATTEMPTS reached — not retried
//   skipped   nothing to send (no valid recipient address)
//   dry_run   rendered but not sent (NOTIFICATIONS_DRY_RUN or {"dry_run":true})
//
// One failing email never stops the rest of the batch. Browsers never call
// this function and it never returns provider errors to end users.

// @ts-ignore: Deno ESM URL import
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { canSendEmail, notificationConfig } from "../_shared/notifications/config.ts";
import { sendNotificationEmail } from "../_shared/notifications/service.ts";

declare const Deno: {
  env: { get(key: string): string | undefined };
  serve(handler: (req: Request) => Promise<Response> | Response): void;
};

const MAX_ATTEMPTS = 6;
// Delay before attempt n+1, indexed by attempts already made (1-based).
const BACKOFF_MINUTES = [1, 5, 15, 60, 180];
const DEFAULT_BATCH = 25;
const SEND_SPACING_MS = 550;   // stays under Resend's default rate limit
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Row = {
  id: string;
  organization_id: string;
  event_type: string;
  to_profile_ids: string[];
  cc_profile_ids: string[];
  template_data: Record<string, unknown>;
  subject: string | null;
  attempts: number;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const secret = notificationConfig.dispatchSecret;
  if (!secret) {
    console.error("send-notifications: NOTIFICATIONS_DISPATCH_SECRET is not set");
    return json({ error: "Not configured." }, 500);
  }
  if (!safeEqual(req.headers.get("x-notifications-secret") || "", secret)) {
    return json({ error: "Forbidden." }, 403);
  }

  try {
    return await dispatch(req);
  } catch (err) {
    console.error("send-notifications: unexpected error", err instanceof Error ? err.message : err);
    return json({ error: "Dispatch failed." }, 500);
  }
});

async function dispatch(req: Request): Promise<Response> {
  let body: { limit?: number; organization_id?: string; dry_run?: boolean; preview?: boolean } = {};
  try { body = await req.json(); } catch { /* empty body is fine */ }

  const dryRun = body.dry_run === true || notificationConfig.dryRun;
  const orgFilter = body.organization_id && UUID_RE.test(body.organization_id) ? body.organization_id : null;
  const limit = Math.min(Math.max(Number(body.limit) || DEFAULT_BATCH, 1), 100);

  // Without a sender on the verified domain nothing can be sent. Leave the
  // queue untouched (rows expire on their own schedule) instead of burning
  // retry attempts.
  if (!dryRun && !canSendEmail()) {
    console.warn("send-notifications: RESEND_API_KEY or NOTIFICATION_FROM_EMAIL not set — queue left pending");
    return json({ status: "not_configured", processed: 0 });
  }

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

  const { data: claimed, error: claimErr } = await admin.rpc("claim_email_notifications", {
    p_limit: limit, p_org: orgFilter,
  });
  if (claimErr) {
    console.error("send-notifications: claim failed", claimErr.message);
    return json({ error: "Could not read the notification queue." }, 500);
  }

  const rows = (claimed as Row[]) || [];
  const counts: Record<string, number> = {};
  const previews: unknown[] = [];

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    let patch: Record<string, unknown>;

    try {
      const outcome = await sendNotificationEmail(admin, {
        id: row.id,
        organizationId: row.organization_id,
        type: row.event_type,
        toProfileIds: row.to_profile_ids || [],
        ccProfileIds: row.cc_profile_ids || [],
        data: row.template_data || {},
        subject: row.subject,
      }, { dryRun });

      switch (outcome.status) {
        case "sent":
          patch = {
            status: "sent", sent_at: new Date().toISOString(), provider_message_id: outcome.providerMessageId,
            subject: outcome.subject, recipient_email: outcome.to.join(", "), cc_emails: outcome.cc,
            error_message: null,
          };
          break;
        case "dry_run":
          patch = {
            status: "dry_run", subject: outcome.subject, recipient_email: outcome.to.join(", "),
            cc_emails: outcome.cc, error_message: "Dry run — rendered, not sent.",
          };
          if (body.preview) {
            previews.push({ id: row.id, type: row.event_type, subject: outcome.subject, to: outcome.to, cc: outcome.cc, text: outcome.text, html: outcome.html });
          }
          break;
        case "skipped":
          patch = { status: "skipped", error_message: outcome.reason };
          break;
        default: {
          const giveUp = outcome.status === "failed" || row.attempts >= MAX_ATTEMPTS;
          const delay = BACKOFF_MINUTES[Math.min(row.attempts, BACKOFF_MINUTES.length) - 1] ?? 180;
          patch = {
            status: giveUp ? "failed" : "retry",
            next_attempt_at: new Date(Date.now() + delay * 60_000).toISOString(),
            error_message: outcome.error.slice(0, 1000),
            ...(outcome.subject ? { subject: outcome.subject } : {}),
            ...(outcome.to ? { recipient_email: outcome.to.join(", "), cc_emails: outcome.cc } : {}),
          };
          console.warn(`send-notifications: ${row.event_type} ${row.id} ${giveUp ? "failed" : "will retry"}: ${outcome.error}`);
        }
      }
    } catch (err) {
      // Defensive: sendNotificationEmail does not throw, but a failure here
      // must not stop the batch.
      const delay = BACKOFF_MINUTES[Math.min(row.attempts, BACKOFF_MINUTES.length) - 1] ?? 180;
      patch = {
        status: row.attempts >= MAX_ATTEMPTS ? "failed" : "retry",
        next_attempt_at: new Date(Date.now() + delay * 60_000).toISOString(),
        error_message: `Unexpected: ${err instanceof Error ? err.message : String(err)}`.slice(0, 1000),
      };
    }

    const { error: updErr } = await admin.from("email_notifications")
      .update({ ...patch, locked_at: null })
      .eq("id", row.id);
    if (updErr) console.error(`send-notifications: could not record outcome for ${row.id}`, updErr.message);

    const status = String(patch.status);
    counts[status] = (counts[status] || 0) + 1;
    if (status === "sent" && i < rows.length - 1) await sleep(SEND_SPACING_MS);
  }

  return json({ processed: rows.length, counts, ...(body.preview ? { previews } : {}) });
}
