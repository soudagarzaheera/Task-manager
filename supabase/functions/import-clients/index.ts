// Supabase Edge Function: import-clients
//
// Server-side validation and insert for the bulk "Import Clients" screen.
// Every row is checked against the same rules as the Add Client form
// (saveClient() in index.html), then inserted with the CALLER'S OWN JWT —
// so RLS (clients_insert: organization, company scope and, from 036, Assistant Manager
// rank) applies exactly as it does to the Add Client form. The service-role
// key is used for one read only: looking up which client codes / PANs are
// already taken anywhere in the organization, because client codes are
// unique organization-wide but a Manager can only see their own company's
// clients. No client data from that lookup is returned to the caller.
//
// Request:  POST { rows: ClientRow[], dryRun?: boolean, onboardedDate?: "YYYY-MM-DD" }
// Response: { results: [{ row, status: "ready"|"imported"|"duplicate"|"failed",
//                         reason?, warnings?, client? }] }
//   dryRun: validate only — status "ready" instead of inserting.
//
// Retries are safe: a client code that already exists is reported as
// "duplicate" and never inserted twice (also backed by uq_org_client_code).

// @ts-ignore: Deno ESM URL import
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

declare const Deno: {
  env: { get(key: string): string | undefined };
  serve(handler: (req: Request) => Promise<Response> | Response): void;
};

// Mirrors RANK / CAN.manageClients() in index.html and auth_rank() (030).
// Adding clients: Assistant Manager and above — MANAGER_RANK in index.html,
// clients_insert in 036 (Assistant Managers have the Manager permissions).
const RANK: Record<string, number> = {
  partner: 90, manager: 70, assistant_manager: 60, senior_executive: 50, accounts: 40,
  senior_associate: 30, associate: 20, trainee: 10,
};
const MANAGE_CLIENTS_RANK = 60;

// Client type is free text (047, chk_clients_entity_type): any value, stored as
// entered after trimming. Blank keeps the Add Client default.
const DEFAULT_TYPE = "Private Ltd";
export const MAX_TYPE_LENGTH = 100;

const MAX_ROWS = 200; // per request — the browser sends larger files in chunks
const CODE_RE = /^[A-Z0-9]{2,8}$/;
const PAN_RE = /^[A-Z]{5}[0-9]{4}[A-Z]$/;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

const ALLOWED_ORIGINS = new Set([
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  ...(Deno.env.get("ALLOWED_ORIGINS") || "").split(",").map((s: string) => s.trim()).filter(Boolean),
]);
const HIDE_ERROR_DETAILS = (Deno.env.get("HIDE_ERROR_DETAILS") || "").toLowerCase() === "true";

type Json = (body: unknown, status?: number) => Response;
type BackendError = { message?: string; code?: string; details?: string; hint?: string };

export type ClientRow = {
  row: number; code?: unknown; name?: unknown; type?: unknown; pan?: unknown;
  gstin?: unknown; email?: unknown; phone?: unknown; partner?: unknown;
};
export type RowResult = {
  row: number;
  status: "ready" | "imported" | "duplicate" | "failed";
  reason?: string;
  warnings?: string[];
  client?: Record<string, unknown>;
};
type Clean = {
  row: number; code: string; name: string; type: string; pan: string; gstin: string;
  email: string; phone: string; partnerCode: string;
};

function describe(err: unknown): string {
  if (!err) return "";
  if (err instanceof Error) return err.message;
  const e = err as BackendError;
  return [e.code, e.message, e.details, e.hint].filter(Boolean).join(" | ");
}

function corsFor(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") || "";
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
  if (ALLOWED_ORIGINS.has(origin)) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

const str = (v: unknown) => (v === null || v === undefined ? "" : String(v)).trim();

function validDate(s: string): boolean {
  if (!DATE_RE.test(s)) return false;
  const d = new Date(s + "T00:00:00Z");
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

/* Same checks, same order and same wording as saveClient() in index.html,
   plus an email format check (bulk import only). Returns the cleaned row or
   the reason it is invalid. */
export function cleanRow(r: ClientRow): { ok: true; row: Clean } | { ok: false; reason: string } {
  const code = str(r.code).toUpperCase();
  const name = str(r.name);
  const pan = str(r.pan).toUpperCase();
  const gstin = str(r.gstin).toUpperCase();
  const email = str(r.email);
  const phone = str(r.phone);
  const typeIn = str(r.type);
  const partnerCode = str(r.partner);
  if (!code) return { ok: false, reason: "A short code is required" };
  if (!CODE_RE.test(code)) return { ok: false, reason: "Short code: 2–8 letters or digits, no spaces" };
  if (!name) return { ok: false, reason: "Enter the client name" };
  if (pan && !PAN_RE.test(pan)) return { ok: false, reason: "PAN should look like AABCS1234K" };
  if (gstin && gstin.length !== 15) return { ok: false, reason: "A GSTIN is 15 characters" };
  if (email && !EMAIL_RE.test(email)) return { ok: false, reason: "Enter a valid email address" };
  if (typeIn.length > MAX_TYPE_LENGTH) return { ok: false, reason: `Type can be at most ${MAX_TYPE_LENGTH} characters` };
  const type = typeIn || DEFAULT_TYPE;
  if (!partnerCode) return { ok: false, reason: "Choose a relationship partner" };
  return { ok: true, row: { row: Number(r.row) || 0, code, name, type, pan, gstin, email, phone, partnerCode } };
}

Deno.serve(async (req: Request) => {
  const corsHeaders = corsFor(req);
  const json: Json = (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  try {
    return await handle(req, json);
  } catch (err) {
    console.error("import-clients: unexpected exception", err);
    return json({ error: "Unexpected server error while importing clients." }, 500);
  }
});

async function handle(req: Request, json: Json): Promise<Response> {
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !ANON_KEY) {
    console.error("import-clients: missing Supabase environment configuration");
    return json({ error: "Server is not configured correctly." }, 500);
  }

  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "Not authenticated." }, 401);

  // Acts as the caller: every read of profiles and every insert goes through RLS.
  const userDb = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false },
  });
  const { data: authData, error: authErr } = await userDb.auth.getUser();
  if (authErr || !authData?.user) {
    return json({ error: "Your session is invalid or has expired. Sign in again." }, 401);
  }

  const { data: caller, error: callerErr } = await userDb
    .from("profiles")
    .select("id, organization_id, role, is_active, company_id")
    .eq("auth_user_id", authData.user.id)
    .maybeSingle();
  if (callerErr) {
    console.error("import-clients: failed to load caller profile", describe(callerErr));
    return json({ error: "Could not verify your account." }, 500);
  }
  if (!caller || !caller.is_active || (RANK[caller.role] || 0) < MANAGE_CLIENTS_RANK) {
    return json({ error: "Assistant Manager and above can add clients." }, 403);
  }
  if (!caller.company_id) return json({ error: "Your profile has no company." }, 400);

  const fail = (status: number, error: string, cause?: unknown) => {
    const detail = describe(cause);
    if (cause) console.error(`import-clients: ${error}`, detail);
    return json(HIDE_ERROR_DETAILS || !detail ? { error } : { error, detail }, status);
  };

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, "Invalid request body.");
  }
  const rows = Array.isArray(body.rows) ? (body.rows as ClientRow[]) : null;
  if (!rows || !rows.length) return fail(400, "No rows to import.");
  if (rows.length > MAX_ROWS) return fail(400, `Send at most ${MAX_ROWS} rows per request.`);
  const dryRun = body.dryRun === true;

  // Onboarded date = the importer's "today" (the Add Client form uses the
  // browser's local date). Accepted only within a day of the server's date.
  const serverToday = new Date().toISOString().slice(0, 10);
  const asked = str(body.onboardedDate);
  const dayMs = 86400000;
  const onboarded = validDate(asked) &&
      Math.abs(Date.parse(asked + "T00:00:00Z") - Date.parse(serverToday + "T00:00:00Z")) <= dayMs
    ? asked
    : serverToday;

  const orgId = caller.organization_id as string;
  const results: RowResult[] = [];
  const valid: Clean[] = [];
  for (const r of rows) {
    const c = cleanRow(r);
    if (c.ok) valid.push(c.row);
    else results.push({ row: Number(r.row) || 0, status: "failed", reason: c.reason });
  }

  // Relationship partner: any active employee the caller can see (profiles
  // RLS keeps company scope), of any designation — the same people the Add
  // Client form's dropdown offers — matched by employee code. It marks who
  // handles the client and grants no access.
  const partnerCodes = [...new Set(valid.map((v) => v.partnerCode))];
  const partners = new Map<string, string>();
  if (partnerCodes.length) {
    const { data: ppl, error: pplErr } = await userDb
      .from("profiles")
      .select("id, employee_code, is_active, deleted_at")
      .eq("organization_id", orgId)
      .in("employee_code", partnerCodes);
    if (pplErr) return fail(500, "Could not check the relationship partners.", pplErr);
    for (const p of ppl || []) {
      if (p.is_active && !p.deleted_at) partners.set(String(p.employee_code), p.id);
    }
  }

  // Organization-wide duplicate check (service role, read-only, codes and PANs only).
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
  const codes = [...new Set(valid.map((v) => v.code))];
  const pans = [...new Set(valid.map((v) => v.pan).filter(Boolean))];
  const takenCodes = new Set<string>();
  const takenPans = new Set<string>();
  if (codes.length) {
    const { data, error } = await admin.from("clients").select("client_code")
      .eq("organization_id", orgId).in("client_code", codes);
    if (error) return fail(500, "Could not check for existing clients.", error);
    for (const d of data || []) takenCodes.add(String(d.client_code));
  }
  if (pans.length) {
    const { data, error } = await admin.from("clients").select("pan")
      .eq("organization_id", orgId).in("pan", pans);
    if (error) return fail(500, "Could not check for existing clients.", error);
    for (const d of data || []) takenPans.add(String(d.pan));
  }

  const seenCodes = new Set<string>();
  const seenPans = new Set<string>();
  for (const v of valid) {
    if (takenCodes.has(v.code)) {
      results.push({ row: v.row, status: "duplicate", reason: `Client code ${v.code} already exists` });
      continue;
    }
    if (seenCodes.has(v.code)) {
      results.push({ row: v.row, status: "duplicate", reason: `Client code ${v.code} appears earlier in this file` });
      continue;
    }
    seenCodes.add(v.code);
    const partnerId = partners.get(v.partnerCode);
    if (!partnerId) {
      results.push({
        row: v.row, status: "failed",
        reason: `Relationship partner ${v.partnerCode} was not found — use the employee code of an active employee`,
      });
      continue;
    }
    const warnings: string[] = [];
    if (v.pan && takenPans.has(v.pan)) warnings.push("This PAN is already used by another client in your organization");
    else if (v.pan && seenPans.has(v.pan)) warnings.push("This PAN appears earlier in this file");
    if (v.pan) seenPans.add(v.pan);

    if (dryRun) {
      results.push({ row: v.row, status: "ready", ...(warnings.length ? { warnings } : {}) });
      continue;
    }

    // Same payload as saveClient() for a new client. company_id is the
    // importer's own company, as on the Add Client form.
    const { data: inserted, error: insErr } = await userDb.from("clients").insert({
      organization_id: orgId, client_code: v.code, name: v.name, entity_type: v.type,
      pan: v.pan, gstin: v.gstin, email: v.email, phone: v.phone,
      relationship_partner_id: partnerId, onboarded_date: onboarded, is_active: true,
      company_id: caller.company_id,
    }).select().single();

    if (insErr) {
      if (insErr.code === "23505") {
        results.push({ row: v.row, status: "duplicate", reason: `Client code ${v.code} already exists` });
      } else if (insErr.code === "42501") {
        results.push({ row: v.row, status: "failed", reason: "You do not have permission to add this client" });
      } else {
        console.error("import-clients: insert failed", describe(insErr));
        results.push({
          row: v.row, status: "failed",
          reason: "Could not add the client" + (HIDE_ERROR_DETAILS ? "" : " — " + (insErr.message || "database error")),
        });
      }
      continue;
    }
    results.push({ row: v.row, status: "imported", client: inserted, ...(warnings.length ? { warnings } : {}) });
  }

  results.sort((a, b) => a.row - b.row);
  return json({ results });
}
