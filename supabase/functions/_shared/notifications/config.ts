// Server-side configuration for application notification emails.
//
// Every value comes from Supabase Edge Function secrets — none of these are
// ever sent to, or readable by, a browser/mobile/desktop client.
//
//   RESEND_API_KEY                 required to send (already set on the project)
//   NOTIFICATION_FROM_EMAIL        required to send, on the verified Resend domain,
//                                  e.g. "Fynalliance <notifications@fynalliance.com>"
//   NOTIFICATION_REPLY_TO          optional reply-to address
//   NOTIFICATION_APP_NAME          optional, shown in the header/footer (default "Task Manager")
//   APP_BASE_URL                   optional deep/universal link base, e.g. https://app.fynalliance.com
//                                  — when unset, emails are sent without buttons
//   NOTIFICATIONS_DISPATCH_SECRET  required; shared with pg_cron (Vault) to call the dispatcher
//   NOTIFICATIONS_DRY_RUN          "true" = render and log, never call Resend

declare const Deno: { env: { get(key: string): string | undefined } };

const env = (key: string) => (Deno.env.get(key) || "").trim();

export const notificationConfig = {
  get resendApiKey() { return env("RESEND_API_KEY"); },
  get fromEmail() { return env("NOTIFICATION_FROM_EMAIL"); },
  get replyTo() { return env("NOTIFICATION_REPLY_TO"); },
  get appName() { return env("NOTIFICATION_APP_NAME") || "Task Manager"; },
  get appBaseUrl() { return env("APP_BASE_URL"); },
  get dispatchSecret() { return env("NOTIFICATIONS_DISPATCH_SECRET"); },
  get dryRun() { return env("NOTIFICATIONS_DRY_RUN").toLowerCase() === "true"; },
};

/** True when a real email can be sent (key + a sender on the verified domain). */
export function canSendEmail(): boolean {
  return Boolean(notificationConfig.resendApiKey && notificationConfig.fromEmail);
}
