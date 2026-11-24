-- EXPLAIN ANALYZE for the nine queries timed in ../05_query_timings.md.
-- Run after 03_schema.sql and seed.sql; measured_plans.txt is its output.
\set repo '''org3/repo3'''
\echo == Q1 installation credentials (1-E)
EXPLAIN ANALYZE SELECT i.installation_id, i.ai_url, i.ai_model, i.ai_key
  FROM repos r JOIN installations i ON i.installation_id = r.installation_id
 WHERE r.repo = :repo;
\echo == Q2 per-user rate limit (4-B)
EXPLAIN ANALYZE SELECT COUNT(*) FROM command_hits
 WHERE repo = :repo AND user_login = 'user42'
   AND hit_at > extract(epoch from now()) - 3600;
\echo == Q3 per-repo rate limit (4-C)
EXPLAIN ANALYZE SELECT COUNT(*) FROM command_hits
 WHERE repo = :repo AND hit_at > extract(epoch from now()) - 3600;
\echo == Q4 dashboard summary (10)
EXPLAIN ANALYZE SELECT r.repo, r.duplicates_caught,
    COALESCE(cs.total_commands, 0), COALESCE(rc.total_reviews, 0),
    COALESCE(km.total_kudos, 0), COALESCE(rm.open_reminders, 0),
    COALESCE(qw.median_wait, 0), COALESCE(qw.p95_wait, 0)
  FROM repos r
  LEFT JOIN (SELECT repo, SUM(run_count) AS total_commands FROM command_stats WHERE repo = :repo GROUP BY repo) cs ON cs.repo = r.repo
  LEFT JOIN (SELECT repo, SUM(review_count) AS total_reviews FROM review_counts WHERE repo = :repo GROUP BY repo) rc ON rc.repo = r.repo
  LEFT JOIN (SELECT repo, SUM(kudos_count) AS total_kudos FROM kudos WHERE repo = :repo GROUP BY repo) km ON km.repo = r.repo
  LEFT JOIN (SELECT repo, COUNT(*) AS open_reminders FROM reminders WHERE repo = :repo GROUP BY repo) rm ON rm.repo = r.repo
  LEFT JOIN (SELECT repo,
                    percentile_cont(0.5)  WITHIN GROUP (ORDER BY wait_seconds) AS median_wait,
                    percentile_cont(0.95) WITHIN GROUP (ORDER BY wait_seconds) AS p95_wait
               FROM queue_waits WHERE repo = :repo GROUP BY repo) qw ON qw.repo = r.repo
 WHERE r.repo = :repo;
\echo == Q5 reminders due now (7-B)
EXPLAIN ANALYZE SELECT r.reminder_id, r.repo, r.number, r.author, r.due_at, r.text,
       i.installation_id, i.ai_url, i.ai_model, i.ai_key
  FROM reminders r
  JOIN repos rp ON rp.repo = r.repo
  JOIN installations i ON i.installation_id = rp.installation_id
 WHERE r.due_at <= extract(epoch from now())
 ORDER BY r.due_at;
\echo == Q6 session lookup (11-C)
EXPLAIN ANALYZE SELECT login, token, expires_at FROM web_sessions
 WHERE session_id = 'sess-42' AND expires_at > extract(epoch from now());
\echo == Q7 queue wait statistics (8-B)
EXPLAIN ANALYZE SELECT COUNT(*), AVG(wait_seconds), MIN(wait_seconds), MAX(wait_seconds),
       percentile_cont(0.5)  WITHIN GROUP (ORDER BY wait_seconds),
       percentile_cont(0.95) WITHIN GROUP (ORDER BY wait_seconds)
  FROM queue_waits WHERE repo = :repo;
\echo == Q8 vote tally (6-C)
EXPLAIN ANALYZE SELECT choice, COUNT(*) AS votes FROM vote_ballots
 WHERE repo = :repo AND number = 1 GROUP BY choice ORDER BY votes DESC;
\echo == Q9 insert and prune queue_waits (8-A)
BEGIN;
EXPLAIN ANALYZE INSERT INTO queue_waits (repo, wait_seq, wait_seconds)
SELECT :repo, COALESCE(MAX(wait_seq), 0) + 1, 1.5 FROM queue_waits WHERE repo = :repo;
EXPLAIN ANALYZE DELETE FROM queue_waits
 WHERE repo = :repo
   AND wait_seq <= (SELECT MAX(wait_seq) - 200 FROM queue_waits WHERE repo = :repo);
ROLLBACK;
