// Minimal Resend client (https://resend.com/docs/api-reference/emails/send-email).
// The API key is read from the RESEND_API_KEY secret here and nowhere else,
// and is never logged or returned.

import { notificationConfig } from "./config.ts";

export type ResendMessage = {
  to: string[];
  cc?: string[];
  subject: string;
  html: string;
  text: string;
  tags?: { name: string; value: string }[];
};

export type ResendResult =
  | { ok: true; id: string }
  | { ok: false; transient: boolean; status: number; error: string };

const RESEND_URL = "https://api.resend.com/emails";

/**
 * idempotencyKey: Resend drops a repeat of the same key (24h window), so a
 * retry after a timeout — where the first attempt may have been delivered —
 * can never produce a second email.
 */
export async function sendViaResend(message: ResendMessage, idempotencyKey: string): Promise<ResendResult> {
  const apiKey = notificationConfig.resendApiKey;
  const from = notificationConfig.fromEmail;
  if (!apiKey || !from) {
    return { ok: false, transient: true, status: 0, error: "Email sending is not configured." };
  }

  const body: Record<string, unknown> = {
    from,
    to: message.to,
    subject: message.subject,
    html: message.html,
    text: message.text,
  };
  if (message.cc && message.cc.length) body.cc = message.cc;
  if (notificationConfig.replyTo) body.reply_to = notificationConfig.replyTo;
  if (message.tags && message.tags.length) body.tags = message.tags;

  let res: Response;
  try {
    res = await fetch(RESEND_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "Idempotency-Key": idempotencyKey,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(20000),
    });
  } catch (err) {
    const name = err instanceof Error ? err.name : "Error";
    return { ok: false, transient: true, status: 0, error: `Network error contacting Resend (${name}).` };
  }

  let payload: { id?: string; message?: string; name?: string } = {};
  try { payload = await res.json(); } catch { /* non-JSON body */ }

  if (res.ok && payload.id) return { ok: true, id: payload.id };

  // 429 (rate limit) and 5xx are temporary; 409 is an idempotency key still
  // being processed. Other 4xx (invalid address, unverified domain, ...) are
  // permanent and must not be retried.
  const transient = res.status === 429 || res.status === 409 || res.status >= 500;
  const detail = [payload.name, payload.message].filter(Boolean).join(": ").slice(0, 400);
  return { ok: false, transient, status: res.status, error: `Resend ${res.status}${detail ? ` — ${detail}` : ""}` };
}
