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
{ "error": true, "code": "SESSION_EXPIRED" | "UNAUTHORIZED" | "FORBIDDEN" | "RATE_LIMITED" | "VALIDATION" | "CONFLICT" | "SERVER", "message": "human readable" }
```
* HTTP 401 + `code: SESSION_EXPIRED|UNAUTHORIZED` → app wipes session and routes to login (once, de-duplicated).
* HTTP 429 `RATE_LIMITED` → app backs off (respect `Retry-After`).
* Internal DB error text is never returned to clients (logged server-side only).

## 5. Public (no session) endpoints
`user_login.php`, `user_register.php`, `send_token.php`, `reset_pwd.php`, `get_countries.php`, `help_api.php`, `privacy.php`, `webhook.php` (signature-verified instead).

## 6. New endpoints
* `logout.php` — POST, revokes current session (or all with `all=1`).
* `account_delete.php` — POST `password`, revokes all sessions, anonymises PII, marks account deleted (App Store 5.1.1(v) / Google Play account-deletion policy).

## 7. Passwords
* Stored with `password_hash(PASSWORD_ARGON2ID)` (fallback `PASSWORD_BCRYPT`). Legacy unsalted sha256 hashes are verified once and transparently upgraded on successful login.
* Login/OTP/PIN endpoints rate limited per IP+identifier (table `rate_limits`).

## 8. Concurrency
* Ride accept / cancel / start / complete transitions use a single conditional `UPDATE ... WHERE id=? AND status IN (...)` and check `affected_rows` — exactly one driver can win a ride; double-tap is idempotent.
* Wallet mutations use `SELECT ... FOR UPDATE` inside a transaction (or atomic `UPDATE bal = bal - ? WHERE bal >= ?`).
