# Pick Me — Client/Server Security Contract (v2)

This is the single source of truth shared by the Flutter app (`lib/`) and the PHP API (`backend/`).

## 1. Transport
* HTTPS only (`https://realpickme.com/endpoint/`). No cleartext traffic.
* Every request carries:
  * `Authorization: <APP_KEY>` — legacy app key (identifies the *app build*, NOT the user). Kept for backward compatibility; **never** trusted for user identity.
  * `X-Session-Token: <token>` — per-user session token (opaque, 64 hex chars) for every user-scoped endpoint.
  * `X-Client-Platform: android|ios`, `X-Client-Version: <semver+build>`.

## 2. Sessions
* Issued by `user_login.php` (and `user_register.php` when it auto-logs-in) inside `login_msg`:
  * `session_token` (string, 64 hex) and `session_expires_at` (ISO-8601 UTC).
* Server stores only `sha256(token)` in table `user_sessions` (see `backend/db/migrations/001_security.sql`).
* Sliding expiry: 30 days, refreshed on use (`last_seen_at`). Revoked by `logout.php`, password change, account deletion.
* App stores the token in `flutter_secure_storage` under key `session_token`. Never in SharedPreferences, never logged.

## 3. Identity rule (IDOR prevention)
* The server derives the acting user (`u_uid`) **from the session**, never from request params.
* If a request still sends `uid` / `user_id` / `rider_id` and it differs from the session user → `403 FORBIDDEN`.
* Driver endpoints additionally resolve `driver_id` from `ride_driver_onboarding`/`ride_drivers` for the session user; client-sent `driver_id` must match or → 403.

## 4. Error envelope
```json
{ "error": true, "code": "SESSION_EXPIRED" | "UNAUTHORIZED" | "FORBIDDEN" | "RATE_LIMITED" | "VALIDATION" | "CONFLICT" | "NOT_FOUND" | "SERVER", "message": "human readable" }
```
* `NOT_FOUND` (added in v2.1): unknown resource **or a resource owned by someone else** (rides are never enumerable).
* Legacy keys are kept alongside the envelope where the app already reads them (`login_msg`, `error_msg`, `data: null`, `drivers: []`, `offers: []`). See §9.2 for which endpoints use which HTTP status.
* HTTP 401 + `code: SESSION_EXPIRED|UNAUTHORIZED` → app wipes session and routes to login (once, de-duplicated).
* HTTP 429 `RATE_LIMITED` → app backs off (respect `Retry-After`).
* Internal DB error text is never returned to clients (logged server-side only).

## 5. Public (no session) endpoints
`user_login.php`, `user_register.php`, `send_token.php`, `reset_pwd.php`, `get_countries.php`, `help_api.php`, `privacy.php`, `terms.php`, `webhook.php` (signature-verified instead).
All of them except `privacy.php`, `terms.php`, `webhook.php` and the e-mailed `reset_pwd.php?token=…` web form still require the app key.

## 6. New endpoints
* `logout.php` — POST, revokes current session (or all with `all=1`).
* `account_delete.php` — POST `password`, revokes all sessions, anonymises PII, marks account deleted (App Store 5.1.1(v) / Google Play account-deletion policy).

## 7. Passwords
* Stored with `password_hash(PASSWORD_ARGON2ID)` (fallback `PASSWORD_BCRYPT`). Legacy unsalted sha256 hashes are verified once and transparently upgraded on successful login.
* Login/OTP/PIN endpoints rate limited per IP+identifier (table `rate_limits`).

## 8. Concurrency
* Ride accept / cancel / start / complete transitions use a single conditional `UPDATE ... WHERE id=? AND status IN (...)` and check `affected_rows` — exactly one driver can win a ride; double-tap is idempotent.
* Wallet mutations use `SELECT ... FOR UPDATE` inside a transaction (or atomic `UPDATE bal = bal - ? WHERE bal >= ?`).

## 9. Server implementation notes (v2.1 — added by the backend; additive unless marked)

### 9.1 Sessions
* `login_msg` (login **and** register) contains `session_token`, `session_expires_at` and, on login, `has_pin` (bool).
* Every authenticated response carries `X-Session-Expires-At: <ISO-8601 UTC>` (sliding expiry; refreshed at most every 5 min).
* 401 `UNAUTHORIZED` = no / unknown token; 401 `SESSION_EXPIRED` = expired, revoked (logout, password change/reset, account deletion) or account no longer active; 403 `FORBIDDEN` = account suspended.
* Max 10 concurrent sessions per user (oldest revoked).
* The identity params checked against the session are `uid`, `user_id`, `rider_id` **and `user`** (sent by most legacy calls).

### 9.2 HTTP status per endpoint (clients must always check `error` in the body)
* Proper codes (401/403/404/409/422/429/5xx): `driver_hub.php`, `ride_*.php`, `drivers_*.php`, `account_delete.php`, `logout.php`, `send_token.php`, `kyc_upgrade.php`, `webhook.php`, `user_logistics.php` (business errors 400 as before).
* Auth / rate-limit errors (401/403/429) use real codes everywhere.
* **Legacy business errors stay HTTP 200 + `error:true` + `code`** (the shipped screens parse 200 bodies): `user_login.php` (wrong credentials = `VALIDATION`, suspended = `FORBIDDEN`), `user_register.php`, `reset_pwd.php`, `set_pin.php`, `validate_pin.php`, `user_info.php` (except `delete_account`), `user_settings.php`, `help_api.php`, `get_countries.php`, `become_driver.php`, `drivers_nearby.php`/`ride_offers.php` lat/lng validation.
* `account_delete.php` (and `user_info.php action=delete_account`): missing password → 422 `VALIDATION`, wrong password → 403 `FORBIDDEN` (never 401), active trip → 409 `CONFLICT`.
* 429 responses carry `Retry-After` and a `retry_after` (seconds) body field.

### 9.3 Idempotency
* `Idempotency-Key` header (also accepted: `X-Idempotency-Key`, params `client_request_id`, `request_id`, `idempotency_key`; 8–64 chars `[A-Za-z0-9_-:.]`).
* Honoured by `ride_book.php`, `user_logistics.php action=book_service`, `driver_hub.php` `accept_ride` / `decline_ride` / `ride_action`: a repeated key (same user, 24 h) replays the original success response with `idempotent_replay: true` and header `Idempotent-Replay: true`. Failures are not stored, so a retry after an error is re-executed.

### 9.4 Rides / driver
* Status vocabulary: `searching, accepted, enroute_pickup, arrived_pickup, in_progress, arrived_destination, completed, canceled` (server writes `canceled`; legacy `cancelled`/`driver_assigned`/`in_ride` are normalised on read). Searching requests expire after 30 min.
* Rider cancel is allowed only before the trip starts (`in_progress` → 409).
* **Changed:** drivers never receive `delivery_otp`; driver payloads carry `requires_otp` (bool) and `otp_verified` (bool). Riders (senders) still get `delivery_otp` from `user_logistics.php` and `ride_history.php role=rider`.
* `verify_otp`: max 5 wrong codes per ride (then 429 locked), idempotent; `complete` of a `dispatch`/`send_me` ride with an OTP requires prior verification (409 otherwise).
* Queue (`dashboard.data.queue`): rides booked for this driver + open requests within 15 km of the driver's fresh fix, filtered by the driver's `allowed_ride_types`, remaining payload capacity and past declines; `rider_phone`/`recipient_phone` are empty until accepted; each item has `pickup_distance_km` when known.
* New action `decline_ride` (`ride_id`): never offered again to that driver; a request booked for that specific driver is closed (`canceled`, reason `driver_declined`).
* `scan_dispatch_batch` is retired → 410.
* GPS: `cancel` and `enroute_pickup` need no fresh fix; arrival/start/complete use a unified 200 m radius + client `accuracy` capped at 50 m. Supplied-but-invalid `lat`/`lng` (0,0 / out of range) → 422. `heartbeat` stores `speed`/`accuracy` and is limited to 60/min.
* Map endpoints only show drivers whose location was updated in the last 90 s (no ghost cars); `drivers_nearby.php` returns `phone` and `nin` as empty strings.
* `ride_complete_trip.php` exists as an alias of `driver_hub.php action=ride_action ride_action=complete`.

### 9.5 Devices / push
* `send_token.php`: params `token`, `install_id` (or `device` JSON containing `install_id`), optional `uid`. Devices are keyed by (`install_id`, session user); without a valid session the device is stored unbound. An install/token is unbound from every other account.
* `logout.php` accepts optional `install_id` / `token` to unbind this device.

### 9.6 Password reset (`reset_pwd.php`)
* Step 1 `email=<email|phone>` → always the same generic success message; e-mails a one-time link (`reset_pwd.php?token=…`, web form) and a 6-digit code, valid 30 min.
* Step 2 (in-app, optional) `email`, `code`, `new_password` → changes the password and revokes all sessions. 5 wrong codes invalidate the request.
