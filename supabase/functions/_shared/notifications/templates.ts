// Email content for every notification type. Each builder receives the
// template_data snapshot queued by the database (see
// migrations/026_email_notifications.sql) and returns layout content.
// Links come only from ./links.ts.

import type { EmailContent, EmailTable } from "./layout.ts";
import {
  fmtDate, fmtDateRange, fmtDateTime, fmtDays, fmtHours, roleLabel, statusLabel, truncate,
} from "./format.ts";
import {
  getApprovalsLink, getBudgetRequestLink, getDailySummaryLink, getJobLink, getLeaveLink,
  getSignInLink, getTaskLink, getTimesheetLink,
} from "./links.ts";

// deno-lint-ignore no-explicit-any
export type TemplateData = Record<string, any>;

export type NotificationType =
  | "task_assigned"
  | "task_due_soon"
  | "task_due_today"
  | "task_overdue"
  | "leave_requested"
  | "leave_approved"
  | "leave_rejected"
  | "budget_requested"
  | "budget_approved"
  | "budget_rejected"
  | "timesheet_submitted"
  | "timesheet_approved"
  | "timesheet_rejected"
  | "partner_daily_summary"
  | "job_closed"
  | "employee_invited"
  | "employee_deactivated"
  | "employee_reactivated";

type Builder = (d: TemplateData) => EmailContent;

const jobLabel = (d: TemplateData) =>
  [d.job_code, d.job_title].filter(Boolean).join(" — ");

const leaveTypeLabel = (d: TemplateData) =>
  d.leave_type_label ? `${d.leave_type_label} (${d.leave_type})` : String(d.leave_type ?? "");

function listTable(heading: string, columns: string[], rows: string[][], total?: number): EmailTable {
  return { heading, columns, rows, more: total && total > rows.length ? total - rows.length : 0 };
}

function timesheetTable(entries: TemplateData[] | undefined): EmailTable[] {
  const list = Array.isArray(entries) ? entries : [];
  const shown = list.slice(0, 30);
  return [listTable(
    "Entries",
    ["Date", "Job code", "Task", "Hours", "Work done"],
    shown.map((e) => [fmtDate(e.date), e.job_code || "", e.task || "—", fmtHours(e.hours), truncate(e.narration, 160)]),
    list.length,
  )];
}

const taskReminderDetails = (d: TemplateData): EmailContent["details"] => [
  ["Task", d.task_title],
  ["Job code", jobLabel(d)],
  ["Client", d.client_name],
  ["Assigned to", d.employee_name],
  ["Due date", fmtDate(d.due_date)],
  ["Status", statusLabel(d.task_status)],
];

export const TEMPLATES: Record<NotificationType, Builder> = {
  task_assigned: (d) => ({
    subject: `New Task Assigned: ${d.job_code} - ${d.task_title}`,
    preheader: `${d.assigned_by_name || "Your team"} assigned you "${d.task_title}", due ${fmtDate(d.due_date)}.`,
    title: d.is_reassignment ? "A task has been reassigned to you" : "A new task has been assigned to you",
    intro: `${d.employee_name} has been assigned "${d.task_title}" on ${d.job_code}` +
      (d.client_name ? ` for ${d.client_name}` : "") + ".",
    details: [
      ["Employee", d.employee_name],
      ["Client / site", d.client_name],
      ["Job code", jobLabel(d)],
      ["Task", d.task_title],
      ["Assigned by", d.assigned_by_name],
      ["Due date", fmtDate(d.due_date)],
      ["Budgeted hours (task)", fmtHours(d.estimated_hours)],
      ["Budgeted hours (job)", fmtHours(d.job_budget_hours)],
      ["Previously assigned to", d.is_reassignment ? d.previous_assignee_name : null],
    ],
    action: { label: "Open task", url: getTaskLink(d.task_id) },
    tone: "info",
  }),

  task_due_soon: (d) => ({
    subject: `Task Due Soon: ${d.job_code} - ${d.task_title}`,
    preheader: `"${d.task_title}" is due on ${fmtDate(d.due_date)}.`,
    title: `Task due in ${d.days_until_due} day${d.days_until_due === 1 ? "" : "s"}`,
    intro: `"${d.task_title}" on ${d.job_code} is due on ${fmtDate(d.due_date)} and is not complete yet.`,
    details: taskReminderDetails(d),
    action: { label: "Open task", url: getTaskLink(d.task_id) },
    tone: "info",
  }),

  task_due_today: (d) => ({
    subject: `Task Due Today: ${d.job_code} - ${d.task_title}`,
    preheader: `"${d.task_title}" is due today.`,
    title: "Task due today",
    intro: `"${d.task_title}" on ${d.job_code} is due today (${fmtDate(d.due_date)}) and is not complete yet.`,
    details: taskReminderDetails(d),
    action: { label: "Open task", url: getTaskLink(d.task_id) },
    tone: "warn",
  }),

  task_overdue: (d) => ({
    subject: `Overdue Task: ${d.job_code} - ${d.task_title}`,
    preheader: `"${d.task_title}" is ${d.days_overdue} day${d.days_overdue === 1 ? "" : "s"} overdue.`,
    title: `Task overdue by ${d.days_overdue} day${d.days_overdue === 1 ? "" : "s"}`,
    intro: `"${d.task_title}" on ${d.job_code} was due on ${fmtDate(d.due_date)} and is still not complete.`,
    details: [
      ["Assigned employee", d.employee_name],
      ["Job code", jobLabel(d)],
      ["Task", d.task_title],
      ["Client", d.client_name],
      ["Original due date", fmtDate(d.due_date)],
      ["Current date", fmtDate(d.today)],
      ["Days overdue", String(d.days_overdue)],
      ["Current status", statusLabel(d.task_status)],
    ],
    action: { label: "Open task", url: getTaskLink(d.task_id) },
    tone: "bad",
  }),

  leave_requested: (d) => ({
    subject: `Leave Request: ${d.employee_name} - ${fmtDateRange(d.from_date, d.to_date)}`,
    preheader: `${d.employee_name} requested ${fmtDays(d.days)} of ${d.leave_type_label || d.leave_type}.`,
    title: "Leave request waiting for your decision",
    intro: `${d.employee_name} has applied for leave and it needs approval.`,
    details: [
      ["Employee", d.employee_name],
      ["Leave type", leaveTypeLabel(d)],
      ["From", fmtDate(d.from_date)],
      ["To", fmtDate(d.to_date)],
      ["Number of days", fmtDays(d.days)],
      ["Status", statusLabel(d.status)],
    ],
    note: d.reason ? { label: "Reason", text: truncate(d.reason, 1000) } : null,
    action: { label: "Review request", url: getLeaveLink(d.request_id) },
    tone: "info",
  }),

  leave_approved: (d) => ({
    subject: `Leave Approved: ${fmtDateRange(d.from_date, d.to_date)}`,
    preheader: `Your ${d.leave_type_label || d.leave_type} was approved by ${d.decided_by_name}.`,
    title: "Your leave has been approved",
    intro: `Your leave request for ${fmtDateRange(d.from_date, d.to_date)} has been approved.`,
    details: [
      ["Leave type", leaveTypeLabel(d)],
      ["Dates", fmtDateRange(d.from_date, d.to_date)],
      ["Number of days", fmtDays(d.days)],
      ["Approved by", d.decided_by_name],
      ["Approval date", fmtDateTime(d.decided_at, d.timezone)],
    ],
    action: { label: "View leave", url: getLeaveLink(d.request_id) },
    tone: "ok",
  }),

  leave_rejected: (d) => ({
    subject: `Leave Request Rejected: ${fmtDateRange(d.from_date, d.to_date)}`,
    preheader: `Your leave request was not approved.`,
    title: "Your leave request was rejected",
    intro: `Your leave request for ${fmtDateRange(d.from_date, d.to_date)} was not approved.`,
    details: [
      ["Leave type", leaveTypeLabel(d)],
      ["Dates", fmtDateRange(d.from_date, d.to_date)],
      ["Number of days", fmtDays(d.days)],
      ["Rejected by", d.decided_by_name],
      ["Decision date", fmtDateTime(d.decided_at, d.timezone)],
    ],
    note: d.rejection_reason ? { label: "Reason", text: truncate(d.rejection_reason, 1000) } : null,
    action: { label: "View leave", url: getLeaveLink(d.request_id) },
    tone: "bad",
  }),

  budget_requested: (d) => ({
    subject: `Budgeted Hours Increase Request: ${d.job_code}`,
    preheader: `${d.employee_name} requested +${fmtHours(d.additional_hours)} on ${d.job_code}.`,
    title: "Request for additional budgeted hours",
    intro: `${d.employee_name} has used the hours available on ${d.job_code} and is asking for more.`,
    details: [
      ["Employee", d.employee_name],
      ["Company", d.company_name],
      ["Job code", jobLabel(d)],
      ["Client", d.client_name],
      ["Original budgeted hours", fmtHours(d.original_budget_hours)],
      ["Currently available", fmtHours(d.from_hours)],
      ["Hours booked so far", fmtHours(d.booked_hours)],
      ["Additional hours requested", fmtHours(d.additional_hours)],
      ["New requested total", fmtHours(d.to_hours)],
      ["Request date", fmtDate(d.requested_date)],
    ],
    note: { label: "Reason", text: truncate(d.reason, 1000) },
    action: { label: "Approve or reject", url: getBudgetRequestLink(d.request_id) },
    tone: "warn",
  }),

  budget_approved: (d) => ({
    subject: `Budgeted Hours Request Approved: ${d.job_code}`,
    preheader: `+${fmtHours(d.additional_hours)} approved on ${d.job_code}.`,
    title: "Additional hours approved",
    intro: `Your request for more hours on ${d.job_code} has been approved. You can now record time against the new budget.`,
    details: [
      ["Job code", jobLabel(d)],
      ["Previous hours available", fmtHours(d.from_hours)],
      ["Additional hours approved", fmtHours(d.additional_hours)],
      ["New total budget", fmtHours(d.to_hours)],
      ["Approved by", d.decided_by_name],
      ["Approval date", fmtDateTime(d.decided_at, d.timezone)],
    ],
    action: { label: "Open job", url: getJobLink(d.job_id) },
    tone: "ok",
  }),

  budget_rejected: (d) => ({
    subject: `Budgeted Hours Request Rejected: ${d.job_code}`,
    preheader: `Your request for +${fmtHours(d.additional_hours)} on ${d.job_code} was not approved.`,
    title: "Additional hours not approved",
    intro: `Your request for more hours on ${d.job_code} was rejected. The job's available hours are unchanged.`,
    details: [
      ["Job code", jobLabel(d)],
      ["Additional hours requested", fmtHours(d.additional_hours)],
      ["Hours available", fmtHours(d.from_hours)],
      ["Rejected by", d.decided_by_name],
      ["Decision date", fmtDateTime(d.decided_at, d.timezone)],
    ],
    note: d.rejection_reason ? { label: "Rejection reason", text: truncate(d.rejection_reason, 1000) } : null,
    action: { label: "Open job", url: getJobLink(d.job_id) },
    tone: "bad",
  }),

  timesheet_submitted: (d) => ({
    subject: `Timesheet Submitted: ${d.employee_name} - Week of ${fmtDate(d.week_start)}`,
    preheader: `${d.employee_name} submitted ${fmtHours(d.hours)} for approval.`,
    title: "Timesheet waiting for your approval",
    intro: `${d.employee_name} submitted ${d.entry_count} time entr${d.entry_count === 1 ? "y" : "ies"} ` +
      `(${fmtHours(d.hours)}) for the week of ${fmtDate(d.week_start)}.`,
    details: [
      ["Employee", d.employee_name],
      ["Period", fmtDateRange(d.first_date, d.last_date)],
      ["Total hours", fmtHours(d.hours)],
    ],
    tables: timesheetTable(d.entries),
    action: { label: "Review timesheet", url: getApprovalsLink() },
    tone: "info",
  }),

  timesheet_approved: (d) => ({
    subject: `Timesheet Approved: Week of ${fmtDate(d.week_start)}`,
    preheader: `${fmtHours(d.hours)} approved by ${d.decided_by_name}.`,
    title: "Your timesheet was approved",
    intro: `${d.decided_by_name} approved ${fmtHours(d.hours)} for the week of ${fmtDate(d.week_start)}.`,
    details: [
      ["Week of", fmtDate(d.week_start)],
      ["Hours approved", fmtHours(d.hours)],
      ["Approved by", d.decided_by_name],
      ["Approval date", fmtDateTime(d.decided_at, d.timezone)],
    ],
    tables: timesheetTable(d.entries),
    action: { label: "View timesheet", url: getTimesheetLink(d.employee_id, d.week_start) },
    tone: "ok",
  }),

  timesheet_rejected: (d) => ({
    subject: `Timesheet Rejected: Week of ${fmtDate(d.week_start)}`,
    preheader: `Time entries were sent back by ${d.decided_by_name}.`,
    title: "Your timesheet was sent back",
    intro: `${d.decided_by_name} sent back ${fmtHours(d.hours)} for the week of ${fmtDate(d.week_start)}. ` +
      `Please correct the entries and submit again.`,
    details: [
      ["Week of", fmtDate(d.week_start)],
      ["Hours sent back", fmtHours(d.hours)],
      ["Rejected by", d.decided_by_name],
      ["Decision date", fmtDateTime(d.decided_at, d.timezone)],
    ],
    note: d.rejection_reason ? { label: "Reason", text: truncate(d.rejection_reason, 1000) } : null,
    tables: timesheetTable(d.entries),
    action: { label: "Fix timesheet", url: getTimesheetLink(d.employee_id, d.week_start) },
    tone: "bad",
  }),

  partner_daily_summary: (d) => {
    const counts = d.counts || {};
    const overdue: TemplateData[] = d.overdue || [];
    const due: TemplateData[] = d.due || [];
    const pending: TemplateData[] = d.pending || [];
    const done: TemplateData[] = d.completed_today || [];
    const otherPendingTotal = Math.max(0, Number(counts.pending || 0) - Number(counts.due || 0) - Number(counts.overdue || 0));
    return {
      subject: `Daily Task Summary: ${fmtDate(d.summary_date)}`,
      preheader: `${counts.overdue || 0} overdue · ${counts.due || 0} due · ${counts.completed_today || 0} completed today`,
      title: `Daily summary for ${fmtDate(d.summary_date)}`,
      intro: `Where your team's tasks stand at the end of the day.`,
      details: [
        ["Pending tasks", String(counts.pending ?? 0)],
        ["Completed today", String(counts.completed_today ?? 0)],
        [`Due (next ${d.due_window_days} days)`, String(counts.due ?? 0)],
        ["Overdue", String(counts.overdue ?? 0)],
      ],
      tables: [
        listTable("Overdue", ["Task", "Job code", "Assigned to", "Due", "Days late"],
          overdue.map((t) => [t.title, t.job_code, t.assignee_name || "Unassigned", fmtDate(t.due_date), String(t.days_overdue)]),
          counts.overdue),
        listTable("Due", ["Task", "Job code", "Assigned to", "Due", "Status"],
          due.map((t) => [t.title, t.job_code, t.assignee_name || "Unassigned", fmtDate(t.due_date), statusLabel(t.status)]),
          counts.due),
        listTable("Completed today", ["Task", "Job code", "Completed by"],
          done.map((t) => [t.title, t.job_code, t.assignee_name || "—"]),
          counts.completed_today),
        listTable("Other pending tasks", ["Task", "Job code", "Assigned to", "Due", "Status"],
          pending.map((t) => [t.title, t.job_code, t.assignee_name || "Unassigned", fmtDate(t.due_date), statusLabel(t.status)]),
          otherPendingTotal),
      ],
      action: { label: "Open dashboard", url: getDailySummaryLink() },
      tone: Number(counts.overdue || 0) > 0 ? "warn" : "info",
    };
  },

  job_closed: (d) => ({
    subject: `Job Closed: ${d.job_code}`,
    preheader: `${d.job_code} has been closed — no more time or tasks can be added.`,
    title: "A job you worked on has been closed",
    intro: `${d.job_code}${d.client_name ? ` for ${d.client_name}` : ""} has been closed. ` +
      `No more time can be booked and no new tasks can be assigned unless it is reopened.`,
    details: [
      ["Job code", jobLabel(d)],
      ["Client", d.client_name],
      ["Closed by", d.closed_by_name],
      ["Closed on", fmtDateTime(d.closed_at, d.timezone)],
      ["Your tasks on this job", d.task_count ? String(d.task_count) : null],
    ],
    note: d.closing_note ? { label: "Closing note", text: truncate(d.closing_note, 1000) } : null,
    action: { label: "Open job", url: getJobLink(d.job_id) },
    tone: "info",
  }),

  employee_invited: (d) => ({
    subject: `You've been added to ${d.company_name}`,
    preheader: `${d.invited_by_name} created your account.`,
    title: `Welcome to ${d.company_name}`,
    intro: `${d.invited_by_name} has added you as ${roleLabel(d.role)}. Sign in with this email address ` +
      `and the password ${d.invited_by_name} shared with you. If you don't have it, use "Forgot password?" on the sign-in screen.`,
    details: [
      ["Name", d.employee_name],
      ["Role", roleLabel(d.role)],
      ["Joining date", fmtDate(d.joining_date)],
      ["Added by", d.invited_by_name],
    ],
    action: { label: "Sign in", url: getSignInLink() },
    tone: "info",
  }),

  employee_deactivated: (d) => ({
    subject: `Account Deactivated: ${d.employee_name}`,
    preheader: `Access to ${d.company_name} has been deactivated.`,
    title: "Account deactivated",
    intro: `${d.employee_name}'s access to ${d.company_name} has been deactivated. ` +
      `Their recorded time and history are kept.`,
    details: [
      ["Employee", d.employee_name],
      ["Role", roleLabel(d.role)],
      ["Last working date", fmtDate(d.exit_date)],
      ["Changed by", d.changed_by_name],
      ["Changed on", fmtDateTime(d.changed_at, d.timezone)],
    ],
    tone: "warn",
  }),

  employee_reactivated: (d) => ({
    subject: `Account Reactivated: ${d.employee_name}`,
    preheader: `Access to ${d.company_name} has been restored.`,
    title: "Account reactivated",
    intro: `${d.employee_name}'s access to ${d.company_name} has been restored.`,
    details: [
      ["Employee", d.employee_name],
      ["Role", roleLabel(d.role)],
      ["Changed by", d.changed_by_name],
      ["Changed on", fmtDateTime(d.changed_at, d.timezone)],
    ],
    action: { label: "Sign in", url: getSignInLink() },
    tone: "ok",
  }),
};

export function isNotificationType(t: string): t is NotificationType {
  return Object.prototype.hasOwnProperty.call(TEMPLATES, t);
}

export function buildEmailContent(type: NotificationType, data: TemplateData): EmailContent {
  return TEMPLATES[type](data);
}
