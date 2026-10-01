// Supabase Edge Function: create-employee
//
// Called by an authenticated administrator's browser (never directly by an
// employee) to provision a brand-new employee: a Supabase Auth account plus
// the linked `profiles` row. This is the ONLY place a new profile row with
// an auth_user_id gets created — the client is not allowed to insert into
// `profiles` directly (see migrations/003_auth_integration.sql).
//
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected
// automatically by the Supabase platform for every Edge Function — nothing
// to configure. The service-role key never leaves this server-side function.

// @ts-ignore: Deno ESM URL import
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

declare const Deno: {
  env: {
    get(key: string): string | undefined;
  };
  serve(handler: (req: Request) => Promise<Response> | Response): void;
};

// Mirrors CAN.manageTeam() in index.html (rank()>=90, which today only the
// "partner" role reaches — "admin" is a schema-level role not currently
// assignable or ranked in the frontend, so it is intentionally excluded here
// too rather than silently granted extra trust).
const ADMIN_ROLES = ["partner"];

// Mirrors ASSIGNABLE_ROLES in index.html — the set of roles the Add Employee
// form is allowed to hand out.
const ASSIGNABLE_ROLES = [
  "partner", "manager", "assistant_manager", "senior_executive",
  "senior_associate", "associate", "trainee",
];

// Browser origins allowed to call this function. Local Vite dev is built in;
// add the deployed site with the optional ALLOWED_ORIGINS secret
// (comma-separated, e.g. "https://tasks.example.com").
const ALLOWED_ORIGINS = new Set([
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  ...(Deno.env.get("ALLOWED_ORIGINS") || "").split(",").map((s: string) => s.trim()).filter(Boolean),
]);

// During development the underlying Postgres/Auth error is returned as
// `detail` so a failure can be diagnosed from the browser. Set the
// HIDE_ERROR_DETAILS=true secret in production to return only `error`.
// Details are only attached once the caller is verified as a partner.
const HIDE_ERROR_DETAILS = (Deno.env.get("HIDE_ERROR_DETAILS") || "").toLowerCase() === "true";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

type BackendError = { message?: string; code?: string; details?: string; hint?: string };
type Json = (body: unknown, status?: number) => Response;

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

Deno.serve(async (req: Request) => {
  const corsHeaders = corsFor(req);
  const json: Json = (body, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  // Preflight: answer before any authentication (browsers send no credentials).
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  // An uncaught exception would otherwise surface as a bare platform 500 with
  // no CORS headers, which the browser reports as an opaque network failure.
  try {
    return await handle(req, json);
  } catch (err) {
    console.error("create-employee: unexpected exception", err);
    return json({ error: "Unexpected server error while creating the employee." }, 500);
  }
});

async function handle(req: Request, json: Json): Promise<Response> {
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !ANON_KEY) {
    console.error("create-employee: missing Supabase environment configuration");
    return json({ error: "Server is not configured correctly." }, 500);
  }

  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!token) return json({ error: "Not authenticated." }, 401);

  // Scoped to the caller's own JWT — used only to confirm who is calling.
  const callerClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false },
  });
  const { data: callerAuth, error: callerAuthErr } = await callerClient.auth.getUser();
  if (callerAuthErr || !callerAuth?.user) {
    return json({ error: "Your session is invalid or has expired. Sign in again." }, 401);
  }

  // Service-role client — bypasses RLS. Used only for the privileged checks
  // and writes below, never to act on data the caller didn't ask for.
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const { data: callerProfile, error: callerProfileErr } = await admin
    .from("profiles")
    .select("id, organization_id, role, is_active, company_id")
    .eq("auth_user_id", callerAuth.user.id)
    .maybeSingle();

  if (callerProfileErr) {
    console.error("create-employee: failed to load caller profile", callerProfileErr);
    return json({ error: "Could not verify your account." }, 500);
  }
  if (!callerProfile || !callerProfile.is_active || !ADMIN_ROLES.includes(callerProfile.role)) {
    return json({ error: "You are not authorized to add employees." }, 403);
  }

  // Caller is a verified, active partner from here on — failures may carry
  // the backend detail (unless HIDE_ERROR_DETAILS is set).
  const fail = (status: number, error: string, cause?: unknown) => {
    const detail = describe(cause);
    if (cause) console.error(`create-employee: ${error}`, detail);
    return json(HIDE_ERROR_DETAILS || !detail ? { error } : { error, detail }, status);
  };

  const orgId = callerProfile.organization_id as string;

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, "Invalid request body.");
  }

  // The employee joins the company chosen on the Add Employee form. Partners
  // manage every company of their organization (028_multi_company.sql), so
  // any ACTIVE company of the caller's own organization is allowed — never
  // one from another organization. Older app builds send no companyId: the
  // employee then joins the caller's own company, as before.
  const requestedCompany = typeof body.companyId === "string" ? body.companyId.trim() : "";
  const companyId = requestedCompany ||
    (typeof callerProfile.company_id === "string" ? callerProfile.company_id.trim() : "");
  if (!companyId) return fail(400, "Select a company for the new employee.");
  if (!UUID_RE.test(companyId)) return fail(400, "The selected company was not found.");

  const { data: companyRow, error: companyErr } = await admin
    .from("companies")
    .select("id, code")
    .eq("organization_id", orgId)
    .eq("id", companyId)
    .eq("is_active", true)
    .maybeSingle();
  if (companyErr) return fail(500, "Could not verify the company.", companyErr);
  if (!companyRow) {
    return fail(400, "The selected company was not found or is inactive.");
  }

  const fullName = String(body.fullName ?? "").trim();
  const email = String(body.email ?? "").trim().toLowerCase();
  const password = String(body.password ?? "");
  const employeeCode = String(body.employeeCode ?? "").trim();
  const role = String(body.role ?? "");
  const reportsTo = body.reportsTo ? String(body.reportsTo) : null;
  const joiningDate = body.joiningDate ? String(body.joiningDate) : new Date().toISOString().slice(0, 10);
  const costPerHour = Number(body.costPerHour) || 0;
  const billRatePerHour = Number(body.billRatePerHour) || 0;

  if (!fullName) return fail(400, "Full name is required.");
  if (!employeeCode) return fail(400, "Employee code is required.");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return fail(400, "Enter a valid email address.");
  if (password.length < 8) return fail(400, "Password must be at least 8 characters.");
  if (!ASSIGNABLE_ROLES.includes(role)) return fail(400, "That role cannot be assigned here.");
  if (costPerHour < 0 || billRatePerHour < 0) return fail(400, "Rates cannot be negative.");
  if (!DATE_RE.test(joiningDate)) return fail(400, "Joining date must be a valid date.");
  if (reportsTo && !UUID_RE.test(reportsTo)) return fail(400, "The selected manager was not found.");

  const { data: existingCode, error: codeCheckErr } = await admin
    .from("profiles")
    .select("id")
    .eq("organization_id", orgId)
    .eq("employee_code", employeeCode)
    .maybeSingle();
  if (codeCheckErr) return fail(500, "Could not validate the employee code.", codeCheckErr);
  if (existingCode) return fail(409, "That employee code is already used.");

  // Same person already on the team (matched by contact email) — say so
  // plainly rather than letting it surface as an auth or insert failure.
  const { data: existingEmail, error: emailCheckErr } = await admin
    .from("profiles")
    .select("id, full_name")
    .eq("organization_id", orgId)
    .ilike("contact_email", email.replace(/[\\%_]/g, "\\$&"))
    .limit(1)
    .maybeSingle();
  if (emailCheckErr) return fail(500, "Could not validate the email address.", emailCheckErr);
  if (existingEmail) {
    return fail(409, `An employee with this email already exists (${existingEmail.full_name}).`);
  }

  if (reportsTo) {
    const { data: bossRow, error: bossErr } = await admin
      .from("profiles")
      .select("id")
      .eq("organization_id", orgId)
      .eq("id", reportsTo)
      .maybeSingle();
    if (bossErr) return fail(500, "Could not validate the reporting line.", bossErr);
    if (!bossRow) return fail(400, "The selected manager was not found.");
  }

  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { full_name: fullName },
  });

  if (createErr) {
    const code = (createErr as { code?: string }).code || "";
    const msg = (createErr.message || "").toLowerCase();
    if (
      code === "email_exists" || code === "user_already_exists" ||
      msg.includes("already been registered") ||
      msg.includes("already registered") ||
      msg.includes("already exists")
    ) {
      return fail(409, "A sign-in account with this email already exists.", createErr);
    }
    if (code === "weak_password" || msg.includes("password")) {
      return fail(400, "The password does not meet the sign-in password requirements.", createErr);
    }
    return fail(500, "Could not create the sign-in account.", createErr);
  }

  const authUserId = created.user?.id;
  if (!authUserId) return fail(500, "Could not create the sign-in account.", "createUser returned no user id");

  // company_id is NOT NULL (migration 012) and is the verified, active company
  // of the caller's organization selected above.
  const profilePayload: Record<string, unknown> = {
    organization_id: orgId,
    auth_user_id: authUserId,
    employee_code: employeeCode,
    full_name: fullName,
    contact_email: email,
    role,
    reports_to: reportsTo,
    joining_date: joiningDate,
    cost_per_hour: costPerHour,
    bill_rate_per_hour: billRatePerHour,
    is_active: true,
    company: companyRow.code,
    company_id: companyRow.id,
  };

  const { data: profile, error: profileErr } = await admin
    .from("profiles")
    .insert(profilePayload)
    .select()
    .single();

  if (profileErr) {
    // Never leave a sign-in account with no employee profile behind it.
    const { error: rollbackErr } = await admin.auth.admin.deleteUser(authUserId);
    if (rollbackErr) console.error("create-employee: rollback deleteUser failed", rollbackErr);

    const text = `${profileErr.message || ""} ${profileErr.details || ""}`.toLowerCase();
    if (profileErr.code === "23505" && text.includes("employee_code")) {
      return fail(409, "That employee code is already used.", profileErr);
    }
    if (profileErr.code === "23505" && text.includes("auth_user_id")) {
      return fail(409, "That sign-in account is already linked to an employee.", profileErr);
    }
    return fail(500, "Could not create the employee profile.", profileErr);
  }

  // Queue the "you have been added" email (sent by send-notifications). The
  // employee already exists at this point, so a queueing problem is only
  // logged — it never fails the request.
  const { error: notifyErr } = await admin.rpc("notif_employee_invited", {
    p_profile: profile.id,
    p_actor: callerProfile.id,
  });
  if (notifyErr) console.error("create-employee: welcome email not queued", describe(notifyErr));

  return json({ profile });
}
