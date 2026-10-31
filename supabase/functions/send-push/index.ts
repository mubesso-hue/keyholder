// send-push: delivers rows from the `notifications` outbox to APNs.
//
// Wire it up as a Database Webhook: table `notifications`, event INSERT,
// HTTP POST to this function, with header `x-webhook-secret: <PUSH_WEBHOOK_SECRET>`.
//
// Required function secrets:
//   APNS_TEAM_ID        Apple developer team id
//   APNS_KEY_ID         id of the .p8 APNs auth key
//   APNS_PRIVATE_KEY    contents of the .p8 file (PEM, newlines allowed)
//   APNS_BUNDLE_ID      the app's bundle id (apns-topic)
//   APNS_ENV            "sandbox" for development builds, "production" for TestFlight/App Store
//   PUSH_WEBHOOK_SECRET shared secret checked on every call
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
};

type WebhookPayload = {
  type: "INSERT" | "UPDATE" | "DELETE";
  table: string;
  record: NotificationRow | null;
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

function apnsHost(): string {
  return Deno.env.get("APNS_ENV") === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
}

// Categories whose target device must act (drop or restore shields), so the
// push also wakes the app in the background.
const WAKES_APP = new Set(["UNLOCK_DECIDED", "BLOCK_ENDED", "KEY_ENDED"]);

async function sendToDevice(token: string, n: NotificationRow): Promise<{ ok: boolean; status: number; reason?: string }> {
  const aps: Record<string, unknown> = {
    alert: { title: n.title, body: n.body },
    sound: "default",
    category: n.category,
    "thread-id": n.category,
  };
  if (WAKES_APP.has(n.category)) aps["content-available"] = 1;

  const res = await fetch(`${apnsHost()}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsJwt()}`,
      "apns-topic": Deno.env.get("APNS_BUNDLE_ID")!,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
      "content-type": "application/json",
    },
    body: JSON.stringify({ aps, category: n.category, data: n.data ?? {}, notification_id: n.id }),
  });

  if (res.ok) return { ok: true, status: res.status };
  let reason: string | undefined;
  try {
    reason = (await res.json())?.reason;
  } catch { /* no body */ }
  return { ok: false, status: res.status, reason };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  const expected = Deno.env.get("PUSH_WEBHOOK_SECRET") ?? "";
  if (!expected || req.headers.get("x-webhook-secret") !== expected) {
    return json({ error: "unauthorized" }, 401);
  }

  let payload: WebhookPayload;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }
  if (payload.type !== "INSERT" || payload.table !== "notifications" || !payload.record) {
    return json({ skipped: true });
  }
  const n = payload.record;

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { data: devices, error } = await supabase
    .from("devices")
    .select("id, apns_token")
    .eq("user_id", n.user_id)
    .not("apns_token", "is", null);
  if (error) return json({ error: error.message }, 500);

  const results: Array<{ device: string; ok: boolean; status: number; reason?: string }> = [];
  for (const d of devices ?? []) {
    const r = await sendToDevice(d.apns_token as string, n);
    results.push({ device: d.id, ...r });
    // Token is dead: forget it so we stop retrying.
    if (!r.ok && (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered")) {
      await supabase.from("devices").update({ apns_token: null }).eq("id", d.id);
    }
  }

  await supabase.from("notifications").update({ sent_at: new Date().toISOString() }).eq("id", n.id);
  return json({ delivered: results.filter((r) => r.ok).length, results });
});
