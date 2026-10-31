# Keyholder

Block the apps that eat your time. Only a friend can give it back.

See `PLAN.md` for the product rules and architecture. This file is the setup checklist.

```
keyholder/
├── PLAN.md
├── supabase/
│   ├── migrations/0001_init.sql      schema, RPCs, RLS, cron  (tested: scripts/test_schema.sh)
│   ├── functions/device-event/       extensions → server, authenticated by device secret
│   ├── functions/send-push/          notifications outbox → APNs
│   └── config.toml
├── scripts/
│   ├── test_schema.sh                runs the migration + scenario on a scratch Postgres
│   └── test_scenario.sql
└── ios/
    ├── project.yml                   XcodeGen spec: app + 3 extensions
    ├── Config.xcconfig               team, bundle id, Supabase URL/key
    ├── Keyholder/                    SwiftUI app
    ├── Shared/                       code compiled into the app and every extension
    ├── KeyholderMonitor/             DeviceActivityMonitor: re-shield / lift / heartbeat
    ├── KeyholderShield/              custom shield UI ("Blocked. Ask Sarah.")
    └── KeyholderShieldAction/        "Ask" button on the shield → unlock request
```

## 0. Preview

`preview/index.html` is a self-contained interactive mock of both phones with the
product rules simulated in JavaScript (same streak, request, Break Glass and
orphan logic as the SQL). Open it in any browser, speed up time, and click
through the flows. It is a UX preview, not the iOS build.

## 1. Supabase

The live backend is project `keyholder` (ref `apatxdwaozoozkigrgbt`, eu-west-1).
Already done there: all three migrations, the per-minute `cron_tick` job, both
edge functions, and the pg_net trigger that hands new `notifications` rows to
`send-push`. `ios/Config.xcconfig` already points at it.

Still needed, and only you can do these:

1. Auth › Providers › **Apple**: enable it and add the app's bundle id
   (`com.keyholder.app`) as an authorized client id. Native Sign in with Apple
   needs nothing else.
2. Edge Functions › Secrets, once you have an APNs key from Apple:
   ```
   APNS_TEAM_ID=XXXXXXXXXX
   APNS_KEY_ID=YYYYYYYYYY
   APNS_PRIVATE_KEY=-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----
   APNS_BUNDLE_ID=com.keyholder.app
   APNS_ENV=sandbox            # production for TestFlight / App Store builds
   ```
   Until these exist, `send-push` leaves rows unsent (`sent_at` null) instead of failing.
   `PUSH_WEBHOOK_SECRET` is optional; the function only delivers rows that are
   already queued in the database, so there is nothing to forge.

To recreate the backend elsewhere:
```bash
supabase link --project-ref <ref>
supabase db push
supabase functions deploy device-event --no-verify-jwt
supabase functions deploy send-push --no-verify-jwt
```
Edit the project URL inside `supabase/migrations/0002_push_webhook.sql` first.

To re-run the schema test locally you need a Postgres 16 server:
```bash
PGHOST=localhost PGPORT=5432 PGUSER=postgres scripts/test_schema.sh
```

## 2. Apple

1. Apple Developer › Identifiers: create the app id with **Family Controls**,
   **App Groups**, **Push Notifications**, **Sign in with Apple**. Create ids for
   the three extensions (`.monitor`, `.shield`, `.shieldaction`) with Family
   Controls and the same App Group.
2. Request the **Family Controls (Distribution)** entitlement at
   developer.apple.com/contact/request/family-controls-distribution. Development
   builds work without it; TestFlight and the App Store do not.
3. Keys: create an **APNs auth key** (.p8). Put its id, your team id and the file
   contents in the Supabase function secrets above.

## 3. Xcode

1. `brew install xcodegen`
2. Edit `ios/Config.xcconfig`: team id, bundle id, app group, Supabase URL and anon key.
   Keep the `https:$()//` form, since `//` starts a comment in xcconfig.
3. ```bash
   cd ios && xcodegen generate && open Keyholder.xcodeproj
   ```
4. Run on a **physical device**. Screen Time APIs do not work in the simulator.
5. Two phones, two Apple IDs, one invite. Lock one, request from the shield,
   approve from the other's lock screen.

## What has and has not been verified

- The SQL schema, every RPC, RLS and the cron tick are exercised end to end by
  `scripts/test_schema.sh` against Postgres 16.
- The two edge functions type-check against a Deno shim.
- The Swift code was written without Xcode available and **has not been compiled**.
  Expect a short round of fixes on first build, most likely around the
  supabase-swift API surface (`SupabaseService.swift`) and SwiftUI bindings.

## Known limits of v1

- iOS lets a user revoke Screen Time access in Settings at any time. The app
  detects it on next launch or heartbeat, ends the block, resets the streak and
  tells the keyholder. It cannot prevent it.
- A force-quit app does not receive background pushes; shields drop when the
  user next opens the app or taps the notification.
- Approved unlocks are at least 15 minutes because DeviceActivity schedules
  cannot be shorter.
- Rest-of-day is computed in the keyholder's timezone when they choose it.
