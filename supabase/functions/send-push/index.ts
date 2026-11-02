// send-push: delivers rows from the `notifications` outbox to APNs.
//
// Triggered by a pg_net call from the database (see migrations/0002_push_webhook.sql)
// with body { record: { id } }. The function never trusts the payload beyond the id:
// it loads the row with the service role and only sends rows that are still unsent.
// That makes the endpoint safe to expose without a shared secret: the worst an
// outsider can do is deliver a notification that was going to be delivered anyway.
// Set PUSH_WEBHOOK_SECRET to additionally require an `x-webhook-secret` header.
//
// Required function secrets:
//   APNS_TEAM_ID        Apple developer team id
//   APNS_KEY_ID         id of the .p8 APNs auth key
//   APNS_PRIVATE_KEY    contents of the .p8 file (PEM, newlines allowed)
//   APNS_BUNDLE_ID      the app's bundle id (apns-topic)
//   APNS_ENV            "sandbox" for development builds, "production" for TestFlight/App Store
// Optional:
//   PUSH_WEBHOOK_SECRET shared secret checked on every call when set
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5";

type NotificationRow = {
  id: number;
  user_id: string;
  title: string;
  body: string;
  category: string;
  data: Record<string, unknown>;
  sent_at: string | null;
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

// APNs tokens are valid for up to an hour; reuse one for 50 minutes.
let cachedJwt: { token: string; issuedAt: number } | null = null;

async function apnsJwt(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt.issuedAt < 50 * 60) return cachedJwt.token;

  const pem = (Deno.env.get("APNS_PRIVATE_KEY") ?? "").replace(/\\n/g, "\n");
  const key = await importPKCS8(pem, "ES256");
  const token = await new SignJWT({ iss: Deno.env.get("APNS_TEAM_ID")! })
    .setProtectedHeader({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID")! })
    .setIssuedAt(now)
    .sign(key);
  cachedJwt = { token, issuedAt: now };
  return token;
}

function apnsConfigured(): boolean {
  return ["APNS_TEAM_ID", "APNS_KEY_ID", "APNS_PRIVATE_KEY", "APNS_BUNDLE_ID"].every((k) => !!Deno.env.get(k));
}

const PRODUCTION = "https://api.push.apple.com";
const SANDBOX = "https://api.sandbox.push.apple.com";

// APNS_ENV picks which server to try first. Development builds (installed
// from Xcode) only accept sandbox; TestFlight and App Store builds only accept
// production. A token sent to the wrong one comes back BadDeviceToken, so we
// retry on the other server. Both kinds of build get pushes from one backend.
function apnsHosts(): [string, string] {
  return Deno.env.get("APNS_ENV") === "production" ? [PRODUCTION, SANDBOX] : [SANDBOX, PRODUCTION];
}

function apnsHost(): string {
  return apnsHosts()[0];
}

// Categories whose target device must act (drop or restore shields), so the
// push also wakes the app in the background.
const WAKES_APP = new Set(["UNLOCK_DECIDED", "BLOCK_ENDED", "KEY_ENDED", "APP_CHANGE_DECIDED", "ALLOWANCE_CHANGED"]);

type SendResult = { ok: boolean; status: number; reason?: string; host?: string };

async function postToApns(host: string, token: string, body: string): Promise<SendResult> {
  const res = await fetch(`${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsJwt()}`,
      "apns-topic": Deno.env.get("APNS_BUNDLE_ID")!,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
      "content-type": "application/json",
    },
    body,
  });
  if (res.ok) return { ok: true, status: res.status, host };
  let reason: string | undefined;
  try {
    reason = (await res.json())?.reason;
  } catch { /* no body */ }
  return { ok: false, status: res.status, reason, host };
}

async function sendToDevice(token: string, n: NotificationRow): Promise<SendResult> {
  const aps: Record<string, unknown> = {
    alert: { title: n.title, body: n.body },
    sound: "default",
    category: n.category,
    "thread-id": n.category,
  };
  if (WAKES_APP.has(n.category)) aps["content-available"] = 1;
  const body = JSON.stringify({ aps, category: n.category, data: n.data ?? {}, notification_id: n.id });

  const [first, second] = apnsHosts();
  const r = await postToApns(first, token, body);
  if (r.ok || r.reason !== "BadDeviceToken") return r;
  return await postToApns(second, token, body);
}

function extractId(payload: unknown): number | null {
  if (!payload || typeof payload !== "object") return null;
  const p = payload as Record<string, unknown>;
  const record = p.record && typeof p.record === "object" ? (p.record as Record<string, unknown>) : null;
  const raw = record?.id ?? p.id;
  const id = typeof raw === "number" ? raw : typeof raw === "string" ? Number(raw) : NaN;
  return Number.isFinite(id) ? id : null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const expected = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (expected && req.headers.get("x-webhook-secret") !== expected) {
    return json({ error: "unauthorized" }, 401);
  }

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  // Health check: { "check": "apns" } reports whether the secrets are present and
  // the private key signs a token. Nothing is sent and nothing is revealed.
  if (payload && typeof payload === "object" && (payload as Record<string, unknown>).check === "apns") {
    const present = Object.fromEntries(
      ["APNS_TEAM_ID", "APNS_KEY_ID", "APNS_PRIVATE_KEY", "APNS_BUNDLE_ID", "APNS_ENV"].map((k) => [k, !!Deno.env.get(k)]),
    );
    let jwtOk = false, jwtError: string | undefined;
    if (apnsConfigured()) {
      try {
        cachedJwt = null;
        await apnsJwt();
        jwtOk = true;
      } catch (e) {
        jwtError = e instanceof Error ? e.message : String(e);
      }
    }
    return json({ present, jwt_ok: jwtOk, jwt_error: jwtError, host: apnsHost() });
  }

  const id = extractId(payload);
  if (id === null) return json({ error: "notification id required" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { data: n, error: loadError } = await supabase
    .from("notifications")
    .select("id, user_id, title, body, category, data, sent_at")
    .eq("id", id)
    .maybeSingle();
  if (loadError) return json({ error: loadError.message }, 500);
  if (!n) return json({ skipped: "not found" }, 404);
  if (n.sent_at) return json({ skipped: "already sent" });

  if (!apnsConfigured()) {
    // Leave sent_at null so the row is retried once APNs secrets exist.
    return json({ skipped: "apns not configured", id });
  }

  const { data: devices, error } = await supabase
    .from("devices")
    .select("id, apns_token")
    .eq("user_id", n.user_id)
    .not("apns_token", "is", null);
  if (error) return json({ error: error.message }, 500);

  const results: Array<{ device: string; ok: boolean; status: number; reason?: string }> = [];
  for (const d of devices ?? []) {
    const r = await sendToDevice(d.apns_token as string, n as NotificationRow);
    results.push({ device: d.id, ...r });
    // Token is dead: forget it so we stop retrying.
    if (!r.ok && (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered")) {
      await supabase.from("devices").update({ apns_token: null }).eq("id", d.id);
    }
  }

  await supabase.from("notifications").update({ sent_at: new Date().toISOString() }).eq("id", n.id);
  return json({ delivered: results.filter((r) => r.ok).length, results });
});
