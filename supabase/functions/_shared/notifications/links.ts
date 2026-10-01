// The ONLY place application links are built. Templates call these helpers and
// never assemble URLs themselves.
//
// Links are "<APP_BASE_URL>/<path>". APP_BASE_URL is meant to become a
// universal/app-link domain (e.g. https://app.fynalliance.com) that opens the
// installed Electron/Android/iOS app on the matching screen; the app does not
// have to be hosted there. Until it is configured every helper returns null
// and emails are sent without a button.
//
// Path contract for the app's deep-link router:
//   /tasks/{taskId}
//   /leave/{leaveRequestId}
//   /timesheets/{profileId}/{weekStartYYYY-MM-DD}
//   /budget-requests/{requestId}
//   /jobs/{jobId}
//   /approvals
//   /summary
//   /sign-in

import { notificationConfig } from "./config.ts";

function baseUrl(): string | null {
  const raw = notificationConfig.appBaseUrl;
  if (!raw) return null;
  try {
    const u = new URL(raw);
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
    return u.toString().replace(/\/+$/, "");
  } catch {
    return null;
  }
}

function appLink(...segments: (string | null | undefined)[]): string | null {
  const base = baseUrl();
  if (!base) return null;
  if (segments.some((s) => s === null || s === undefined || s === "")) return null;
  return [base, ...segments.map((s) => encodeURIComponent(String(s)))].join("/");
}

export const getTaskLink = (taskId: string) => appLink("tasks", taskId);
export const getLeaveLink = (leaveRequestId: string) => appLink("leave", leaveRequestId);
export const getTimesheetLink = (profileId: string, weekStart: string) =>
  appLink("timesheets", profileId, weekStart);
export const getBudgetRequestLink = (requestId: string) => appLink("budget-requests", requestId);
export const getJobLink = (jobId: string) => appLink("jobs", jobId);
export const getApprovalsLink = () => appLink("approvals");
export const getDailySummaryLink = () => appLink("summary");
export const getSignInLink = () => appLink("sign-in");
