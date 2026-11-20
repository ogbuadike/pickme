-- =============================================================================
-- Pick Me — migration 002 (OPTIONAL, run after 001 once the data is clean)
-- Adds uniqueness guarantees the application already assumes. These ALTERs FAIL if duplicates
-- exist, so run the checks first and resolve any rows they return.
-- =============================================================================

-- Checks (must return no rows):
--   SELECT u_uid, COUNT(*) FROM unique_user_table GROUP BY u_uid HAVING COUNT(*) > 1;
--   SELECT email, COUNT(*) FROM unique_user_table WHERE sta <> 2 AND email <> '' GROUP BY email HAVING COUNT(*) > 1;

ALTER TABLE `unique_user_table`
  ADD UNIQUE INDEX IF NOT EXISTS `uq_unique_user_table_u_uid` (`u_uid`);

ALTER TABLE `unique_user_table`
  DROP INDEX IF EXISTS `idx_u_uid`;   -- superseded by the unique index above
