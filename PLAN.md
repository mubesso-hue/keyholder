# Keyholder — Build Plan (v1)

Working name: **Keyholder**. Rename anywhere; nothing depends on it.

## 1. What v1 is

A phone-use limiter for iPhone where you cannot unblock yourself. You pick apps,
tap Lock, and from then on only your **keyholder** can give you time back. Your
keyholder is a friend running the same app on their own phone. Two people who
hold each other's keys are in a **mutual pact**.

Decisions already made:

| Decision | Choice |
| --- | --- |
| Platform | iOS first, native Swift / SwiftUI, iOS 17+ |
| Relationship | One-way keys. Mutual pact = two keys, one each direction |
| Keyholders per locked person | Exactly one in v1. A keyholder may hold many keys |
| Blocking scope | Apps and app categories only. No websites in v1 |
| Escape hatch | Break Glass with a cooling-off delay chosen at Lock time (12 h to 72 h, default 24 h). Keyholder cannot cancel it. No note required |
| Stat | One: current streak (live, "3d 14h") and personal record. Individual, never shared |
| Partner breaks glass in a pact | Your block lifts. Your streak pauses for a 24 h grace window; re-lock with a new keyholder inside it and the streak resumes |
| Backend | Supabase: Postgres + Auth (Sign in with Apple) + Realtime + Edge Functions. Push via APNs |

## 2. The core loop

1. Locked person taps a blocked app. The shield says "Blocked. Ask Sarah." with a
   **Request unlock** button. Or they open the app and tap Request.
2. Keyholder gets a push with quick actions: 15 min, 1 hour, deny. Or opens the
   app and picks 15 / 30 / 60 min, rest of today, or end the block.
3. On approval the locked phone drops its shields for exactly that window and the
   streak pauses. When the window ends, shields return on their own. The locked
   person cannot extend; they ask again.

## 3. Rules

**Keys**
- Invite link carries a mode: *hold my key*, *I'll hold yours*, or *mutual*.
- Lock is disabled until someone holds your key.
- Tightening (blocking more apps) applies instantly, even while locked.
  Opening apps up while locked (*Change apps…* in the ··· menu) is sent to the
  keyholder as a request, like asking for time: they approve or say no, and see
  only counts ("keep 2 more apps open"), never which apps. One app change can
  wait at a time; a new one replaces it. Shortening cooling-off or removing your
  keyholder still needs an ended block.

**Daily allowance**
- Optional, chosen at Lock: N minutes a day on apps you pick. Screen Time counts
  the minutes on the phone; when they're used up those apps block until midnight.
- The keyholder can set it to any size at any time (key page → Change). The
  locked person can turn it down or off, and can ask for more; the keyholder
  approves or says no.
- A change mid-day keeps the minutes already used today.
- A keyholder may resign only when the person they guard has no active block.

**Streak** (continuous time with a live block)
- Approved timed unlocks **pause** the clock. Unlocked minutes are subtracted.
- *End block* by keyholder, Break Glass completion, and detected revocation
  **reset** to zero. The record is kept.
- A missed heartbeat marks the streak *unverified*, not broken. On next launch
  the app checks Screen Time authorization; if revoked, reset and tell the keyholder.
- Orphaned by a partner's Break Glass: block lifts, streak pauses with a 24 h grace.

**Break Glass**
- Cooling-off length chosen at Lock. Can be lengthened any time. Shortening is a request.
- Tap → one honest screen → confirm. Keyholder is pushed immediately.
- During the wait nothing changes on the phone. Card shows countdown + Cancel.
- Cancel keeps the streak. Completion ends the block, ends the key(s) between the
  two people, resets the streak, logs a `break_glass` event, pushes the keyholder.
- In a mutual pact, completion also ends the partner's block as *orphaned*.
- Revoking Screen Time access in iOS Settings is a separate, instant exit the app
  cannot stop. It is logged as `revoked`, resets the streak, and pushes the keyholder.

## 4. Architecture

```
iPhone (locked person)                     Supabase
┌────────────────────────────┐             ┌──────────────────────────────┐
│ Keyholder app (SwiftUI)    │──RPC/REST──▶│ Postgres: profiles, keys,    │
│  - Sign in with Apple      │◀─Realtime───│  blocks, streaks, requests,  │
│  - FamilyActivityPicker    │             │  events, notifications       │
│  - ManagedSettingsStore    │             │  (all writes via SQL RPCs)   │
│  - reconcile(block)        │             │                              │
│                            │             │ pg_cron: cron_tick() 1/min   │
│ Extensions (same App Group)│             │  - complete due Break Glass  │
│  - DeviceActivityMonitor:  │──device-──▶ │  - settle streak pauses      │
│    re-shield when unlock   │  event fn   │  - flag missed heartbeats    │
│    ends; lift on BG done   │             │                              │
│  - ShieldConfiguration:    │             │ Edge fns:                    │
│    "Blocked. Ask Sarah."   │             │  - device-event (secret auth)│
│  - ShieldAction: request   │             │  - send-push (APNs, webhook  │
│    unlock from the shield  │             │    on notifications insert)  │
└────────────────────────────┘             └──────────────┬───────────────┘
                                                          │ APNs
iPhone (keyholder) ◀──────────────────────────────────────┘
  push with actions: Approve 15m / Approve 1h / Deny
```

**Device enforcement (iOS Screen Time API)**
- `AuthorizationCenter.requestAuthorization(for: .individual)` once.
- Lock: `store.shield.applications`, `store.shield.applicationCategories`,
  `store.application.denyAppRemoval = true`. Selection persisted in the App Group.
- Temporary unlock: clear shields, start a `DeviceActivity` schedule ending at
  `unlock_until`. The monitor extension's `intervalDidEnd` re-applies shields even
  if the app is dead. Minimum schedule length is 15 min, so 15 min is the shortest unlock.
- Break Glass: same mechanism with a schedule ending at `break_glass_ends_at`;
  `intervalDidEnd` clears everything. Server cron completes it independently.
- Heartbeat: on foreground, on background refresh, and from the monitor extension,
  posted to `device-event` with a per-device secret (extensions have no user JWT).
- Revocation check: `authorizationStatus != .approved` while a block is active →
  `report_revocation()`.

**Server is the source of truth.** The phone reconciles its shields to the
server's `blocks` row on every launch, push, realtime change, and extension callback.

## 5. Data model

| Table | Purpose |
| --- | --- |
| `profiles` | id = auth user, display name. Auto-created on sign-up |
| `devices` | APNs token + `device_secret` used by extensions |
| `invites` | code, inviter, mode, expiry, accepted_by |
| `keys` | holder_id → locked_id, status. Unique active key per locked_id |
| `blocks` | one active per user: cooling_off_hours, app/category counts, unlock_until, break_glass_ends_at, heartbeat, verified |
| `streaks` | per user: started_at, paused_seconds, pause window, best_seconds, grace_until |
| `unlock_requests` | requester, holder, requested/approved minutes, decision |
| `events` | append-only history (lock, request, approve, break_glass_*, revoked, …) |
| `notifications` | outbox; insert → webhook → `send-push` |

All client writes go through `security definer` RPCs so invariants hold:
`create_invite`, `get_invite`, `accept_invite`, `start_block`, `request_unlock`, `decide_unlock`,
`holder_unlock` (keyholder gives time unasked, e.g. to cut a Break Glass wait short),
`start_break_glass`, `cancel_break_glass`, `complete_break_glass`, `report_revocation`, `end_key`,
`lengthen_cooling_off`, `heartbeat`, `register_device`, `update_display_name`, `me_snapshot`,
plus `device_event` (service role) and `cron_tick`.

## 6. Screens

1. **Sign in** — Sign in with Apple.
2. **Permission** — explain Screen Time access, request it. Skippable for keyholder-only users.
3. **Home** — your card (status, streak, record, Lock / Request / Break Glass) and
   a "Keys you hold" list, each with streak, record, pending request, break-glass countdown.
4. **Lock flow** — pick apps (Apple's picker) → choose cooling-off → confirm.
5. **Request unlock** sheet — 15 / 30 / 60 min, rest of today.
6. **Decide** sheet (keyholder) — 15 / 30 / 60 min, rest of today, end block, deny.
7. **Break Glass** — warning screen; countdown with Cancel while pending.
8. **Invite** — choose mode, share link / code. **Accept** — paste code.
9. **Settings** — name, cooling-off (lengthen only), resign a key, sign out.

## 7. Build order

1. Supabase schema + RPCs + RLS (this repo: `supabase/migrations/0001_init.sql`). Tested locally against Postgres 16.
2. Edge functions `device-event` and `send-push`.
3. iOS project via XcodeGen (`ios/project.yml`): app + 3 extensions + shared code.
4. Sign in, invite, accept, home.
5. Lock flow + shields + monitor extension.
6. Requests + decisions + realtime + push.
7. Break Glass + cron completion.
8. Heartbeat + revocation.
9. TestFlight with two phones.

## 8. Things that need a human

- Apply for the **Family Controls (distribution)** entitlement in the Apple
  developer portal on day one. Development builds work without it, App Store does not.
- Create an **APNs key** (.p8) and put key id / team id / key contents in the
  Supabase function secrets.
- Configure **Sign in with Apple** in Supabase Auth.
- Add a **Database Webhook** on `notifications` insert → `send-push`.
- Enable **pg_cron** and schedule `cron_tick()` every minute (in the migration, needs the extension enabled on the project).

## 9. Not in v1

Websites, multiple keyholders, key transfer, standing auto-approve rules, shared
pact streak, escalating cooling-off, Android.
