-- =============================================================
-- Tidebot SQL Queries (CP3)
-- All queries reference the schema in 03_schema.sql
-- Parameters are written as $1, $2, … (PostgreSQL style)
-- Each query is tagged  -- READ  or  -- WRITE
-- =============================================================

-- ---------------------------------------------------------------
-- 0. Setup helpers (run once)
-- ---------------------------------------------------------------

-- 0-A. Prune command_hits older than 1 hour  -- WRITE
DELETE FROM command_hits
 WHERE hit_at < extract(epoch from now()) - 3600;

-- 0-B. Prune expired oauth_states  -- WRITE
DELETE FROM oauth_states  WHERE expires_at < extract(epoch from now());

-- 0-C. Prune expired web_sessions  -- WRITE
DELETE FROM web_sessions  WHERE expires_at < extract(epoch from now());

-- ---------------------------------------------------------------
-- 1. Installation & repo management
-- ---------------------------------------------------------------

-- 1-A. Upsert an installation (fires on installation webhook)  -- WRITE
INSERT INTO installations (installation_id, ai_url, ai_model, ai_key)
VALUES ($1, $2, $3, $4)
ON CONFLICT (installation_id)
DO UPDATE SET ai_url   = EXCLUDED.ai_url,
              ai_model = EXCLUDED.ai_model,
              ai_key   = EXCLUDED.ai_key;

-- 1-B. Register a repo for an installation (fires when bot is added to repo)  -- WRITE
INSERT INTO repos (repo, installation_id, duplicates_caught)
VALUES ($1, $2, 0)
ON CONFLICT (repo)
DO UPDATE SET installation_id = EXCLUDED.installation_id;

-- 1-C. Insert default config for a new repo  -- WRITE
INSERT INTO repo_config (repo, auto_label, size_labels, star_gate,
                         triage_label, pr_lint, duplicate_check)
VALUES ($1, TRUE, TRUE, FALSE, TRUE, TRUE, TRUE)
ON CONFLICT (repo) DO NOTHING;

-- 1-D. Update a single config flag for a repo (e.g. star_gate)  -- WRITE
UPDATE repo_config
   SET star_gate = $2          -- replace column name as needed
 WHERE repo = $1;

-- 1-E. Fetch installation credentials for a repo (used before every API call)  -- READ
--      Uses JOIN to resolve the FK relationship repos → installations
SELECT i.installation_id, i.ai_url, i.ai_model, i.ai_key
  FROM repos r
  JOIN installations i ON i.installation_id = r.installation_id
 WHERE r.repo = $1;

-- ---------------------------------------------------------------
-- 2. Reviewer rules (CODEOWNERS-style)
-- ---------------------------------------------------------------

-- 2-A. Replace all reviewer rules for a repo (called when .tide.yml is re-read)
-- Step 1: delete existing rules (cascades to reviewer_rule_owners)  -- WRITE
DELETE FROM reviewer_rules WHERE repo = $1;

-- Step 2: insert new rules (repeat for each rule)  -- WRITE
INSERT INTO reviewer_rules (repo, position, pattern)
VALUES ($1, $2, $3);

-- Step 3: insert owners for a rule (repeat for each owner)  -- WRITE
INSERT INTO reviewer_rule_owners (repo, position, owner)
VALUES ($1, $2, $3);

-- 2-B. Find reviewers for a changed file (last matching rule wins)  -- READ
--      Uses JOIN to combine reviewer_rules with reviewer_rule_owners
--      $2 = changed file path; application evaluates glob client-side
SELECT rr.position, rr.pattern, rro.owner
  FROM reviewer_rules rr
  JOIN reviewer_rule_owners rro
    ON rro.repo = rr.repo AND rro.position = rr.position
 WHERE rr.repo = $1
 ORDER BY rr.position;          -- caller picks the last match

-- ---------------------------------------------------------------
-- 3. Command stats  (/stats command and dashboard)
-- ---------------------------------------------------------------

-- 3-A. Increment a command counter (upsert)  -- WRITE
INSERT INTO command_stats (repo, command, run_count)
VALUES ($1, $2, 1)
ON CONFLICT (repo, command)
DO UPDATE SET run_count = command_stats.run_count + 1;

-- 3-B. Total commands run in a repo  -- READ
SELECT SUM(run_count) AS total_commands
  FROM command_stats
 WHERE repo = $1;

-- 3-C. Command breakdown for a repo (dashboard table)  -- READ
SELECT command, run_count
  FROM command_stats
 WHERE repo = $1
 ORDER BY run_count DESC;

-- 3-D. Top repos by command volume (leaderboard)  -- READ
SELECT repo, SUM(run_count) AS total
  FROM command_stats
 GROUP BY repo
 ORDER BY total DESC
 LIMIT 10;

-- ---------------------------------------------------------------
-- 4. Rate limiting
-- ---------------------------------------------------------------

-- 4-A. Record an allowed command invocation  -- WRITE
INSERT INTO command_hits (repo, user_login, hit_at)
VALUES ($1, $2, extract(epoch from clock_timestamp()));

-- 4-B. Per-user count in the last hour  -- READ
SELECT COUNT(*) AS hit_count
  FROM command_hits
 WHERE repo       = $1
   AND user_login = $2
   AND hit_at > extract(epoch from now()) - 3600;

-- 4-C. Per-repo count in the last hour  -- READ
SELECT COUNT(*) AS hit_count
  FROM command_hits
 WHERE repo   = $1
   AND hit_at > extract(epoch from now()) - 3600;

-- ---------------------------------------------------------------
-- 5. Kudos  (/kudos command)
-- ---------------------------------------------------------------

-- 5-A. Give kudos (upsert)  -- WRITE
INSERT INTO kudos (repo, login, kudos_count)
VALUES ($1, $2, 1)
ON CONFLICT (repo, login)
DO UPDATE SET kudos_count = kudos.kudos_count + 1;

-- 5-B. Kudos leaderboard for a repo  -- READ
SELECT login, kudos_count
  FROM kudos
 WHERE repo = $1
 ORDER BY kudos_count DESC
 LIMIT 10;

-- 5-C. Total kudos given in a repo  -- READ
SELECT SUM(kudos_count) AS total_kudos
  FROM kudos
 WHERE repo = $1;

-- ---------------------------------------------------------------
-- 6. Votes  (/vote command)
-- ---------------------------------------------------------------

-- 6-A. Open a new vote  -- WRITE
INSERT INTO votes (repo, number, question, opened_by)
VALUES ($1, $2, $3, $4);

-- 6-B. Cast or change a ballot (upsert)  -- WRITE
INSERT INTO vote_ballots (repo, number, voter, choice)
VALUES ($1, $2, $3, $4)
ON CONFLICT (repo, number, voter)
DO UPDATE SET choice = EXCLUDED.choice;

-- 6-C. Tally the results of a vote  -- READ
SELECT choice, COUNT(*) AS votes
  FROM vote_ballots
 WHERE repo = $1 AND number = $2
 GROUP BY choice
 ORDER BY votes DESC;

-- 6-D. List all open votes in a repo  -- READ
--      A vote row exists until 6-E deletes it; the LEFT JOIN keeps votes that
--      have no ballots yet (ballot_count = 0).
SELECT v.number, v.question, v.opened_by,
       COUNT(b.voter) AS ballot_count
  FROM votes v
  LEFT JOIN vote_ballots b ON b.repo = v.repo AND b.number = v.number
 WHERE v.repo = $1
 GROUP BY v.number, v.question, v.opened_by
 ORDER BY v.number DESC;

-- 6-E. Delete a vote and its ballots (after the vote is closed)  -- WRITE
DELETE FROM votes WHERE repo = $1 AND number = $2;   -- cascades to vote_ballots

-- ---------------------------------------------------------------
-- 7. Reminders  (/remind command)
-- ---------------------------------------------------------------

-- 7-A. Create a reminder  -- WRITE
INSERT INTO reminders (repo, number, author, due_at, text)
VALUES ($1, $2, $3, $4, $5)
RETURNING reminder_id;

-- 7-B. Fetch all reminders due now (called by the scheduler every minute)  -- READ
--      Uses JOIN chain: reminders → repos → installations to retrieve credentials
SELECT r.reminder_id, r.repo, r.number, r.author, r.due_at, r.text,
       i.installation_id, i.ai_url, i.ai_model, i.ai_key
  FROM reminders r
  JOIN repos        rp ON rp.repo = r.repo
  JOIN installations i  ON i.installation_id = rp.installation_id
 WHERE r.due_at <= extract(epoch from now())
 ORDER BY r.due_at;

-- 7-C. Delete a reminder after it has fired  -- WRITE
DELETE FROM reminders WHERE reminder_id = $1;

-- 7-D. Count open reminders across all repos (dashboard)  -- READ
SELECT COUNT(*) AS open_reminders FROM reminders;

-- 7-E. List reminders for a specific issue / PR  -- READ
SELECT reminder_id, author, due_at, text
  FROM reminders
 WHERE repo = $1 AND number = $2
 ORDER BY due_at;

-- ---------------------------------------------------------------
-- 8. AI queue metrics
-- ---------------------------------------------------------------

-- 8-A. Record a queue wait (append; prune if over MAX_WAITS=200)
-- Step 1: insert new row with the next sequence number  -- WRITE
INSERT INTO queue_waits (repo, wait_seq, wait_seconds)
SELECT $1,
       COALESCE(MAX(wait_seq), 0) + 1,
       $2
  FROM queue_waits
 WHERE repo = $1;

-- Step 2: prune oldest rows keeping only the last 200  -- WRITE
DELETE FROM queue_waits
 WHERE repo = $1
   AND wait_seq <= (
       SELECT MAX(wait_seq) - 200
         FROM queue_waits
        WHERE repo = $1
   );

-- 8-B. Queue wait statistics for a repo (dashboard)  -- READ
SELECT COUNT(*)                                                      AS sample_count,
       ROUND(AVG(wait_seconds)::NUMERIC, 3)                         AS avg_wait,
       ROUND(MIN(wait_seconds)::NUMERIC, 3)                         AS min_wait,
       ROUND(MAX(wait_seconds)::NUMERIC, 3)                         AS max_wait,
       ROUND(percentile_cont(0.5) WITHIN GROUP
             (ORDER BY wait_seconds)::NUMERIC, 3)                   AS median_wait,
       ROUND(percentile_cont(0.95) WITHIN GROUP
             (ORDER BY wait_seconds)::NUMERIC, 3)                   AS p95_wait
  FROM queue_waits
 WHERE repo = $1;

-- ---------------------------------------------------------------
-- 9. Review counts  (/review, /security, /perf, … commands)
-- ---------------------------------------------------------------

-- 9-A. Increment a review counter (upsert)  -- WRITE
INSERT INTO review_counts (repo, command, review_count)
VALUES ($1, $2, 1)
ON CONFLICT (repo, command)
DO UPDATE SET review_count = review_counts.review_count + 1;

-- 9-B. Total reviews posted for a repo  -- READ
SELECT SUM(review_count) AS total_reviews
  FROM review_counts
 WHERE repo = $1;

-- 9-C. Duplicates caught (stored on repos, incremented separately)  -- WRITE
UPDATE repos
   SET duplicates_caught = duplicates_caught + 1
 WHERE repo = $1;

-- 9-D. Read duplicates caught for a repo  -- READ
SELECT duplicates_caught FROM repos WHERE repo = $1;

-- ---------------------------------------------------------------
-- 10. Dashboard summary  (all key metrics for one repo in one query)  -- READ
--     Uses LEFT JOINs on five sub-aggregates to build a single-row dashboard
-- ---------------------------------------------------------------
SELECT
    r.repo,
    r.duplicates_caught,
    COALESCE(cs.total_commands,  0)  AS total_commands,
    COALESCE(rc.total_reviews,   0)  AS total_reviews,
    COALESCE(km.total_kudos,     0)  AS total_kudos,
    COALESCE(rm.open_reminders,  0)  AS open_reminders,
    COALESCE(qw.median_wait,     0)  AS median_queue_wait_s,
    COALESCE(qw.p95_wait,        0)  AS p95_queue_wait_s
  FROM repos r
  LEFT JOIN (
      SELECT repo, SUM(run_count)    AS total_commands  FROM command_stats  WHERE repo = $1 GROUP BY repo
  ) cs ON cs.repo = r.repo
  LEFT JOIN (
      SELECT repo, SUM(review_count) AS total_reviews   FROM review_counts  WHERE repo = $1 GROUP BY repo
  ) rc ON rc.repo = r.repo
  LEFT JOIN (
      SELECT repo, SUM(kudos_count)  AS total_kudos     FROM kudos          WHERE repo = $1 GROUP BY repo
  ) km ON km.repo = r.repo
  LEFT JOIN (
      SELECT repo, COUNT(*)          AS open_reminders  FROM reminders      WHERE repo = $1 GROUP BY repo
  ) rm ON rm.repo = r.repo
  LEFT JOIN (
      SELECT repo,
             percentile_cont(0.5)  WITHIN GROUP (ORDER BY wait_seconds) AS median_wait,
             percentile_cont(0.95) WITHIN GROUP (ORDER BY wait_seconds) AS p95_wait
        FROM queue_waits WHERE repo = $1 GROUP BY repo
  ) qw ON qw.repo = r.repo
 WHERE r.repo = $1;

-- ---------------------------------------------------------------
-- 11. Web sessions  (dashboard OAuth – memory-only in production)
-- ---------------------------------------------------------------

-- 11-A. Create a session after OAuth callback  -- WRITE
INSERT INTO web_sessions (session_id, login, token, expires_at)
VALUES ($1, $2, $3, $4);

-- 11-B. Store repo push-access flag for a session  -- WRITE
INSERT INTO session_push_access (session_id, repo, can_push)
VALUES ($1, $2, $3)
ON CONFLICT (session_id, repo)
DO UPDATE SET can_push = EXCLUDED.can_push;

-- 11-C. Look up a session (called on every dashboard page load)  -- READ
SELECT login, token, expires_at
  FROM web_sessions
 WHERE session_id = $1
   AND expires_at > extract(epoch from now());

-- 11-D. Check push access for a repo in a session  -- READ
SELECT can_push
  FROM session_push_access
 WHERE session_id = $1 AND repo = $2;

-- 11-E. Create an OAuth state token (before redirecting to GitHub)  -- WRITE
INSERT INTO oauth_states (state, return_to, expires_at)
VALUES ($1, $2, $3);

-- 11-F. Consume an OAuth state (validate and delete atomically)  -- WRITE
DELETE FROM oauth_states
 WHERE state = $1
   AND expires_at > extract(epoch from now())
RETURNING return_to;
