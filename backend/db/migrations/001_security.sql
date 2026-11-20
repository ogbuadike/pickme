-- =============================================================================
-- Pick Me — migration 001: security / sessions / rate limits / idempotency / hot-path indexes
-- Target: MariaDB 10.5+ (production runs 11.4). Idempotent: safe to run more than once
-- (CREATE TABLE IF NOT EXISTS, ADD COLUMN IF NOT EXISTS, ADD INDEX IF NOT EXISTS, DROP INDEX IF EXISTS).
-- On MySQL 8 the IF [NOT] EXISTS forms of ADD COLUMN / ADD INDEX / DROP INDEX are not supported:
-- run each ALTER once by hand there.
--
-- Run BEFORE deploying the new PHP code:
--   mysql --default-character-set=utf8mb4 -u <user> -p <db> < backend/db/migrations/001_security.sql
-- Take a backup first (mysqldump --single-transaction). ALTERs on ride_rides / unique_user_table
-- use the online (INPLACE / INSTANT) algorithm in MariaDB 10.6+, except the DECIMAL conversions
-- (COPY) — schedule this during low traffic.
-- =============================================================================

SET NAMES utf8mb4;

-- -----------------------------------------------------------------------------
-- 1. Per-user sessions (contract §2). Only sha256(token) is stored.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `user_sessions` (
  `id`            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `u_uid`         VARCHAR(64)  NOT NULL,
  `token_hash`    CHAR(64)     CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `created_at`    DATETIME     NOT NULL,           -- UTC
  `last_seen_at`  DATETIME     NOT NULL,           -- UTC (sliding expiry, touched at most every 5 min)
  `expires_at`    DATETIME     NOT NULL,           -- UTC
  `revoked_at`    DATETIME     NULL DEFAULT NULL,  -- UTC
  `revoke_reason` VARCHAR(32)  NULL DEFAULT NULL,
  `ip`            VARCHAR(45)  NULL DEFAULT NULL,
  `user_agent`    VARCHAR(255) NULL DEFAULT NULL,
  `platform`      VARCHAR(16)  NULL DEFAULT NULL,
  `app_version`   VARCHAR(32)  NULL DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_user_sessions_token` (`token_hash`),
  KEY `idx_user_sessions_uid` (`u_uid`, `revoked_at`, `expires_at`),
  KEY `idx_user_sessions_expires` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- -----------------------------------------------------------------------------
-- 2. Rate limiting (fixed windows; one row per bucket/key/window, pruned lazily).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `rate_limits` (
  `bucket`       VARCHAR(40)  CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `key_hash`     CHAR(64)     CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `window_start` INT UNSIGNED NOT NULL,
  `hits`         INT UNSIGNED NOT NULL DEFAULT 1,
  `expires_at`   INT UNSIGNED NOT NULL,
  PRIMARY KEY (`bucket`, `key_hash`, `window_start`),
  KEY `idx_rate_limits_expires` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=ascii COLLATE=ascii_bin;

-- -----------------------------------------------------------------------------
-- 3. Password resets (one-time link token + 6-digit code, both stored hashed).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `password_resets` (
  `id`         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `u_uid`      VARCHAR(64)  NOT NULL,
  `token_hash` CHAR(64)     CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `code_hash`  CHAR(64)     CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `attempts`   TINYINT UNSIGNED NOT NULL DEFAULT 0,
  `expires_at` DATETIME     NOT NULL,   -- UTC
  `used_at`    DATETIME     NULL DEFAULT NULL,
  `ip`         VARCHAR(45)  NULL DEFAULT NULL,
  `created_at` DATETIME     NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_password_resets_token` (`token_hash`),
  KEY `idx_password_resets_uid` (`u_uid`, `used_at`, `expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- -----------------------------------------------------------------------------
-- 4. Payment webhook idempotency (Flutterwave). UNIQUE(provider, provider_tx_id).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `payment_events` (
  `id`             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `provider`       VARCHAR(20)   NOT NULL,
  `provider_tx_id` VARCHAR(64)   NOT NULL,
  `tx_ref`         VARCHAR(128)  NULL DEFAULT NULL,
  `flw_ref`        VARCHAR(128)  NULL DEFAULT NULL,
  `u_uid`          VARCHAR(64)   NULL DEFAULT NULL,
  `amount`         DECIMAL(15,2) NULL DEFAULT NULL,
  `fee`            DECIMAL(15,2) NULL DEFAULT NULL,
  `status`         ENUM('received','processed','rejected','orphan') NOT NULL DEFAULT 'received',
  `payload`        MEDIUMTEXT    NULL,
  `created_at`     DATETIME      NOT NULL,
  `updated_at`     DATETIME      NOT NULL,
  `processed_at`   DATETIME      NULL DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_payment_events_provider_tx` (`provider`, `provider_tx_id`),
  KEY `idx_payment_events_uid` (`u_uid`),
  KEY `idx_payment_events_status` (`status`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- -----------------------------------------------------------------------------
-- 5. User settings (previously created at runtime by user_settings.php).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `user_settings_table` (
  `id`           INT(11) NOT NULL AUTO_INCREMENT,
  `user_uid`     VARCHAR(64) NOT NULL,
  `push_notif`   TINYINT(1) DEFAULT 1,
  `sms_notif`    TINYINT(1) DEFAULT 1,
  `email_promos` TINYINT(1) DEFAULT 0,
  `loc_access`   TINYINT(1) DEFAULT 1,
  `share_ride`   TINYINT(1) DEFAULT 0,
  `language`     VARCHAR(20) DEFAULT 'English',
  `theme`        VARCHAR(20) DEFAULT 'System',
  PRIMARY KEY (`id`),
  UNIQUE KEY `user_uid` (`user_uid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- -----------------------------------------------------------------------------
-- 6. unique_user_table
--    pass_code / access are TEXT already: argon2id (~97 chars) and bcrypt (60) hashes fit,
--    so no widening is required. Money moves to DECIMAL (was DOUBLE).
--    sta: 0 = active, 1 = suspended, 2 = deleted (account_delete.php).
-- -----------------------------------------------------------------------------
ALTER TABLE `unique_user_table`
  ADD COLUMN IF NOT EXISTS `emergency_contact` VARCHAR(100) DEFAULT '',
  ADD COLUMN IF NOT EXISTS `deleted_at` DATETIME NULL DEFAULT NULL,
  MODIFY `bal` DECIMAL(15,2) NOT NULL DEFAULT 0.00;

ALTER TABLE `unique_user_table`
  DROP INDEX IF EXISTS `idx_unique_user_table_u_uid`;          -- exact duplicate of idx_u_uid

-- -----------------------------------------------------------------------------
-- 7. unique_account_table (wallet ledger): DECIMAL money + per-user history index.
-- -----------------------------------------------------------------------------
ALTER TABLE `unique_account_table`
  MODIFY `amount` DECIMAL(15,2) NULL DEFAULT NULL,
  ADD INDEX IF NOT EXISTS `idx_uat_user_id` (`user_uid`, `id`),
  ADD INDEX IF NOT EXISTS `idx_uat_reference` (`reference`(64));

-- -----------------------------------------------------------------------------
-- 8. ride_rides: delivery OTP attempt tracking, booking idempotency, hot-path indexes.
--    Hot queries and the index serving each:
--      ride_status (no id)         rider_id,status,updated_at   idx_ride_rides_rider_status   (existing)
--      busy-driver checks          driver_id,status              idx_rr_driver_status          (existing)
--      driver active ride          driver_id,status,updated_at   idx_ride_rides_driver_status_updated (existing)
--      driver queue                status,driver_id,created_at   idx_ride_rides_search_queue   (existing)
--      expiry sweep                status,created_at             idx_ride_rides_status_created (existing)
--      drivers_poll deletes        status,updated_at             idx_rr_status_updated         (new)
--      dispatch batch scan (bbox)  status,ride_type,pickup_lat   idx_rr_dispatch_scan          (new)
--      idempotent booking          rider_id,idempotency_key      uq_rr_rider_idem              (new, UNIQUE)
-- -----------------------------------------------------------------------------
ALTER TABLE `ride_rides`
  ADD COLUMN IF NOT EXISTS `delivery_otp_attempts` TINYINT UNSIGNED NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS `delivery_otp_verified_at` DATETIME NULL DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS `idempotency_key` VARCHAR(64) NULL DEFAULT NULL;

ALTER TABLE `ride_rides`
  ADD UNIQUE INDEX IF NOT EXISTS `uq_rr_rider_idem` (`rider_id`, `idempotency_key`),
  ADD INDEX IF NOT EXISTS `idx_rr_status_updated` (`status`, `updated_at`),
  ADD INDEX IF NOT EXISTS `idx_rr_dispatch_scan` (`status`, `ride_type`, `pickup_lat`, `pickup_lng`);

-- Redundant indexes on the hottest write table (exact duplicates or left prefixes of another index).
ALTER TABLE `ride_rides`
  DROP INDEX IF EXISTS `idx_driver_status`,            -- = idx_rr_driver_status
  DROP INDEX IF EXISTS `idx_rider_status`,             -- = idx_rr_rider_status
  DROP INDEX IF EXISTS `idx_status`,                   -- = idx_rr_status
  DROP INDEX IF EXISTS `idx_ride_rides_driver_status`, -- = idx_ride_rides_driver_status_updated
  DROP INDEX IF EXISTS `idx_rr_driver`,                -- prefix of idx_rr_driver_status
  DROP INDEX IF EXISTS `idx_rr_rider`,                 -- prefix of idx_rr_rider_status
  DROP INDEX IF EXISTS `idx_rr_status`;                -- prefix of idx_ride_rides_status_created

-- -----------------------------------------------------------------------------
-- 9. ride_driver_locations: bounding-box lookups (drivers_nearby / ride_offers / drivers_poll)
--    WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ? AND updated_at >= ?
--    → range on lat, lng + updated_at evaluated from the index (ICP), then PK join to ride_drivers.
-- -----------------------------------------------------------------------------
ALTER TABLE `ride_driver_locations`
  ADD INDEX IF NOT EXISTS `idx_rdl_bbox` (`lat`, `lng`, `updated_at`);

ALTER TABLE `ride_driver_locations`
  DROP INDEX IF EXISTS `idx_rdl_lat_lng`,                       -- prefix of idx_rdl_bbox
  DROP INDEX IF EXISTS `uq_ride_driver_locations_driver_id`;    -- duplicate of the PRIMARY KEY

-- -----------------------------------------------------------------------------
-- 10. ride_drivers: new profiles start OFFLINE (was DEFAULT 1); drop duplicate indexes.
-- -----------------------------------------------------------------------------
ALTER TABLE `ride_drivers`
  ALTER COLUMN `is_online` SET DEFAULT 0;

ALTER TABLE `ride_drivers`
  DROP INDEX IF EXISTS `idx_phone`,      -- = idx_ride_drivers_phone
  DROP INDEX IF EXISTS `idx_nin`,        -- = idx_ride_drivers_nin
  DROP INDEX IF EXISTS `idx_is_online`;  -- prefix of idx_ride_drivers_online (is_online, id)

-- -----------------------------------------------------------------------------
-- 11. app_users (FCM device registry): device fingerprint lookup + token lookup.
-- -----------------------------------------------------------------------------
ALTER TABLE `app_users`
  ADD COLUMN IF NOT EXISTS `device_hash` CHAR(64) NULL DEFAULT NULL;

UPDATE `app_users` SET `device_hash` = SHA2(`device_info`, 256) WHERE `device_hash` IS NULL;

ALTER TABLE `app_users`
  ADD INDEX IF NOT EXISTS `idx_app_users_device_hash` (`device_hash`),
  ADD INDEX IF NOT EXISTS `idx_app_users_token` (`u_token`(255));

-- -----------------------------------------------------------------------------
-- 12. Session-less legacy state: the old app-wide "keep-alive"/web-panel session
--     data is not used by the API any more. Nothing to migrate.
-- -----------------------------------------------------------------------------
