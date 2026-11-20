# Pick Me — PHP API

JSON API for the Pick Me Flutter app (ride-hailing, campus rides, Send Me errands, Dispatch parcels).
Served from `https://realpickme.com/endpoint/`. The client/server security contract is
[`docs/SECURITY_CONTRACT.md`](../docs/SECURITY_CONTRACT.md) — read §9 for server-specific details.

```
backend/
  endpoint/                 web-served API (see .htaccess: only listed endpoints are reachable)
    security.php            central helpers: envelope, app key, sessions, rate limits, validation, DB, tx
    ride_api_bootstrap.php  ride helpers + ride state machine (PM_RIDE_TRANSITIONS)
    activities.php          wallet ledger, activity log, image storage, account deletion, e-mails
    push_alert.php          push helpers (FCM HTTP v1)
    auth.php                legacy checkAuthorization() shim (app key only)
    *.php                   endpoints
  unique/                   NOT web-accessible (.htaccess: deny all)
    unique_1.php            .env loader: env_data()
    unique_con.php          mysqli connection ($dbconn)
    pm_mail.php             PHPMailer wrapper + neutral Pick Me template
    pm_fcm.php              FCM HTTP v1 sender (service-account JWT → OAuth2 token, cached)
    mail/PHPMailer-master/  vendored PHPMailer 6.7.1
  db/migrations/            SQL migrations (run in order)
```

## Requirements

* PHP 8.1+ (production: 8.4) with `mysqli` (mysqlnd), `openssl`, `curl`, `gd` (with WebP), `mbstring`, `sodium`
  (argon2id support in `password_hash`). APCu optional (FCM token / country / expiry-sweep caching).
* MariaDB 10.5+ (production 11.4). MySQL 8 works but run the `IF [NOT] EXISTS` ALTERs by hand.
* Apache 2.4 with `AllowOverride All` (or equivalent nginx rules, see below), `mod_rewrite`, `mod_headers`.
* PHP-FPM / FastCGI recommended: push + e-mail are sent after `fastcgi_finish_request()`.

## Configuration (.env)

The loader reads `<DOCUMENT_ROOT>/.required/.env` (one `KEY=VALUE` per line; `#` comments).
For CLI/cron set `PICKME_ENV_FILE=/abs/path/.env`. Real environment variables are a fallback.
**Protect `.required/` from the web** (see Deploy step 3) and `chmod 600` the file.

| Key | Required | Purpose |
|---|---|---|
| `DATAUSER`, `DATAPASS`, `DATANAME` | yes | MySQL credentials |
| `DATAHOST`, `DATAPORT` | no | default `localhost`, `3306` |
| `APP_KEY_SHA256` | yes | comma-separated accepted app-key hashes (the value the app sends in `Authorization`). Supports rotation: list old + new. If unset the legacy key is accepted and a warning is logged. |
| `HOST`, `EMAIL`, `EMAIL_PASSWORD` | yes | SMTP host / user / password |
| `SMTP_PORT`, `SMTP_SECURE` | no | default `587`, `tls` (`ssl` for 465) |
| `MAIL_FROM`, `MAIL_FROM_NAME`, `SUPPORT_EMAIL` | no | sender address/name, support address in footers |
| `FLW_SECRET_HASH` | yes | Flutterwave webhook secret hash (compared to the `verif-hash` header). Legacy name `SECRET_Hash_Webhook` is still read. |
| `FLW_SECRET_KEY` | yes | Flutterwave secret key (transaction verification, virtual accounts, BVN). Legacy name `API_KEY_live` is still read. |
| `FLW_VA_BVN` | no | BVN used for permanent virtual accounts at sign-up. If unset, sign-up skips the virtual account (it can be created at KYC). **The previously hard-coded BVN has been removed.** |
| `FLW_API_BASE` | no | override Flutterwave base URL (testing only) |
| `FCM_SERVICE_ACCOUNT_JSON` | yes (for push) | absolute path to the Firebase service-account JSON, **outside the web root**, chmod 600 |
| `FCM_PROJECT_ID` | no | defaults to `project_id` in the JSON |
| `FCM_TOKEN_CACHE_DIR` | no | where the OAuth2 access token is cached (default system temp dir; APCu used when available) |
| `UFITPAY_API_KEY`, `UFITPAY_API_TOKEN` | for KYC | card-holder KYC (previously hard-coded — rotate them) |
| `BVN_CONSENT_REDIRECT_URL` | no | BVN consent redirect (default `https://realpickme.com/bvnconsent`) |
| `PUBLIC_BASE_URL` | no | public URL of `endpoint/` used for uploaded image URLs and reset links (default `https://realpickme.com/endpoint`) |
| `PUBLIC_SITE_URL` | no | site URL in e-mails (default `https://realpickme.com`) |
| `TRUSTED_PROXY_IPS` | no | comma-separated proxy IPs whose `X-Forwarded-For` is trusted for rate limiting |

## Deploy

1. **Back up** the database (`mysqldump --single-transaction --routines realaqqw_mpicklogis_me > backup.sql`) and the current `endpoint/` + `unique/` folders.
2. **Run migrations in order** (idempotent; can be re-run):
   ```
   mysql --default-character-set=utf8mb4 -u USER -p DB < db/migrations/001_security.sql
   # optional, after the duplicate checks inside the file return no rows:
   mysql --default-character-set=utf8mb4 -u USER -p DB < db/migrations/002_unique_constraints.sql
   ```
   001 converts `bal` / `amount` to `DECIMAL(15,2)` (table copy) — run it in a quiet period.
   The new code must not be deployed before 001 (it needs `user_sessions`, `rate_limits`, `password_resets`,
   `payment_events`, `idempotency_keys`, `ride_declines` and the new columns).
3. **Secrets**
   * Add the keys above to `.required/.env`; `chmod 600`.
   * Deny web access to it: `<DOCUMENT_ROOT>/.required/.htaccess` containing `Require all denied`
     (better: move the folder above the document root and set `PICKME_ENV_FILE`).
   * Move the Firebase service-account JSON **out of `endpoint/fcm_vendor/`** (it was publicly downloadable)
     and point `FCM_SERVICE_ACCOUNT_JSON` at it. `endpoint/fcm_vendor/` (Kreait SDK) is no longer used — delete it.
   * **Rotate every credential that was in the repository / web root**: the legacy FCM server key, the
     Ufitpay key/token, the SMTP passwords that were in `unique/mail/index.php` and
     `unique/mail/_Email_sender/index.php`, the Firebase service-account key, the Flutterwave keys, and set a
     new `FLW_SECRET_HASH` in the Flutterwave dashboard.
4. **Upload code**: the endpoints look for their shared files in `endpoint/unique/` first and fall back to a sibling `unique/`. The simplest deploy is the zip layout: upload `endpoint/` with `unique/` inside it, so a legacy `public_html/unique/` used by other sites is never touched. Otherwise replace `endpoint/` and `unique/` and include the `.htaccess` files. Make sure files deleted in
   this release are removed on the server too (an rsync without `--delete` leaves them reachable):
   `endpoint/domain_ip.php`, `endpoint/3third_party_req.php`, `endpoint/fbfcm.php`, `endpoint/fbcfcm2.php`,
   `unique/unique_func.php`, `unique/unique_all_pg.php`, `unique/unique_plugin.php`, `unique/unique_code.php`,
   `unique/unique_gtm.php`, `unique/token.php`, `unique/mail/index.php`, `unique/mail/_Email_sender/`,
   `unique/mail/PHPMailer-master/get_oauth_token.php`, and any `error_log*` / `*.log` files in `endpoint/`.
5. **Writable folders** (owned by the PHP user, `0755`): `endpoint/uploads/` (packages, driver documents, KYC)
   and `endpoint/img/users/`. Uploaded images are re-encoded to WebP with random names; the `.htaccess` blocks
   script execution there. Driver/KYC documents are still served by unguessable URL — moving them outside the
   web root behind an authenticated admin download is recommended.
6. **Smoke test**: `user_login.php` returns `login_msg.session_token`; an authenticated call with
   `X-Session-Token` returns `X-Session-Expires-At`; `security.php`, `unique/unique_1.php`, `.required/.env`
   return 403/404 from the web.
7. **Flutterwave webhook URL**: `https://realpickme.com/endpoint/webhook.php` with the new secret hash.

### Release compatibility

Every user-scoped endpoint now requires `X-Session-Token`. App builds that predate the session contract get
`401 UNAUTHORIZED` and must update — ship the new app build before (or together with) this backend, and consider
forcing an update for old versions.

### nginx equivalent

```
location ^~ /unique/            { deny all; }
location ^~ /.required/         { deny all; }
location ~ ^/endpoint/(uploads|img)/.*\.(php|phtml|phar)$ { deny all; }
location ~ ^/endpoint/(account_delete|become_driver|driver_hub|drivers_nearby|drivers_poll|drivers_update_location|get_countries|help_api|kyc_upgrade|logout|privacy|reset_pwd|ride_book|ride_cancel_booking|ride_complete_trip|ride_history|ride_offers|ride_start_trip|ride_status|send_token|set_pin|terms|transaction_history|user_info|user_login|user_logistics|user_register|user_settings|validate_pin|webhook)\.php$ {
    include fastcgi_params; fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name; fastcgi_pass php-fpm;
}
location ~ ^/endpoint/.*\.(webp|jpe?g|png|gif)$ { add_header X-Content-Type-Options nosniff; }
location ^~ /endpoint/ { deny all; }
```

## Endpoints

Every request (except `privacy.php`, `terms.php`, `webhook.php` and the e-mailed reset form) needs the app key
in `Authorization`. "Session" = `X-Session-Token` required; the acting user is always the session user and any
`uid` / `user_id` / `rider_id` / `user` param must match it (else 403).

| Endpoint | Auth | Notes |
|---|---|---|
| `user_login.php` | public | rate limited (IP 30/5 min, identifier 8/15 min); issues session; `has_pin` |
| `user_register.php` | public | IP 10/h; argon2id; issues session |
| `reset_pwd.php` | public | request → generic reply + e-mailed link & code; complete via code or web form |
| `send_token.php` | public (session optional) | FCM token keyed by (`install_id`, session user) |
| `get_countries.php`, `help_api.php` | public | read-only |
| `privacy.php`, `terms.php` | none | static HTML |
| `webhook.php` | `verif-hash` | Flutterwave; idempotent per transaction id |
| `logout.php` | session | `all=1`, optional `install_id` / `token` |
| `account_delete.php` | session | `password`; anonymises PII |
| `user_info.php` | session | profile, password / PIN / emergency contact / avatar updates, `delete_account` |
| `user_settings.php`, `set_pin.php`, `validate_pin.php`, `transaction_history.php` | session | |
| `ride_book.php`, `ride_status.php`, `ride_cancel_booking.php`, `ride_start_trip.php`, `ride_history.php` | session | ownership enforced (rider or assigned driver) |
| `ride_offers.php`, `drivers_nearby.php`, `drivers_poll.php` | session | bounding-box + 90 s freshness |
| `user_logistics.php` | session | Send Me / Dispatch booking, server-side pricing |
| `become_driver.php`, `kyc_upgrade.php` | session | |
| `driver_hub.php`, `drivers_update_location.php`, `ride_complete_trip.php` | session + activated driver | driver resolved from session |

## Design notes

* **SQL**: every query is a prepared statement (`pm_q_one/pm_q_all/pm_exec/pm_insert`); mysqli runs in strict
  mode, the global exception handler logs details and returns `{"error":true,"code":"SERVER"}`.
* **Ride state machine**: `PM_RIDE_TRANSITIONS` in `ride_api_bootstrap.php`; each transition is a conditional
  `UPDATE … WHERE id=? AND <owner>=? AND status IN (…)` checked via `affected_rows`, under the ride row lock;
  repeats are idempotent and never move money twice.
* **Wallet**: `pm_wallet_debit()` = `UPDATE … SET bal = bal - ? WHERE u_uid = ? AND bal >= ?`; credits/debits and
  ledger rows are written in the same transaction as the ride transition / webhook event (`pm_tx()` retries
  deadlocks).
* **Rate limits**: table `rate_limits`, fixed windows, single-statement upsert (`LAST_INSERT_ID(hits+1)`);
  fails open (logged) if the table is unavailable.
* **Logs**: `error_log()` JSON lines prefixed `[pickme]`; no passwords, tokens, OTPs or PINs are logged.
