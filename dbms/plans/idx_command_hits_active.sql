-- Index: command_hits_active_idx
-- Purpose: Speed up per-user and per-repo rate-limit checks
--          by pre-filtering to hits in the last hour.
--
-- Note: PostgreSQL partial indexes with volatile functions like now()
--       are NOT automatically updated as time passes. This index is
--       included as a reference; in production prefer a plain index on
--       (repo, user_login, hit_at) combined with a pruning job that
--       deletes rows older than 1 hour (see Q0 in 04_queries.sql).
--
-- If you do use this, rebuild it periodically:
--   REINDEX INDEX CONCURRENTLY command_hits_active_idx;

CREATE INDEX IF NOT EXISTS command_hits_active_idx
    ON command_hits (repo, user_login, hit_at DESC)
 WHERE hit_at > extract(epoch from now()) - 3600;
