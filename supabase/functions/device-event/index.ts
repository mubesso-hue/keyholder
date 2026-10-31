// device-event: entry point for the iOS extensions, which have no user JWT.
// They authenticate with the per-device secret issued by register_device().
//
// POST { secret: string, type: "heartbeat" | "request_unlock" | "revoked" | "break_glass_done", payload?: object }
//
// Deploy with JWT verification off (see supabase/config.toml); the device
// secret is the credential here.

import { createClient } from "npm:@supabase/supabase-js@2";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });

const ALLOWED = new Set(["heartbeat", "request_unlock", "revoked", "break_glass_done"]);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  let body: { secret?: unknown; type?: unknown; payload?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  const secret = typeof body.secret === "string" ? body.secret : "";
  const type = typeof body.type === "string" ? body.type : "";
  const payload = body.payload && typeof body.payload === "object" ? body.payload : {};

  if (!secret || !ALLOWED.has(type)) return json({ error: "secret and a known type are required" }, 400);

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  const { data, error } = await supabase.rpc("device_event", {
    p_secret: secret,
    p_type: type,
    p_payload: payload,
  });

  if (error) {
    const unauthorized = error.message.includes("unknown device");
    return json({ error: error.message }, unauthorized ? 401 : 400);
  }
  return json(data);
});
