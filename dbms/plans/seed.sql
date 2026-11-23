-- Synthetic data for the timings in ../05_query_timings.md.
-- Run after ../03_schema.sql on an empty database:
--   psql -f dbms/03_schema.sql -f dbms/plans/seed.sql
-- Sizes: 5 installations, 100 repos, 500 users, 10 000 command hits,
-- 200 votes with 2 000 ballots, 1 000 reminders, 200 queue waits per repo.
-- setseed() makes every run produce the same rows.

SELECT setseed(0.42);

INSERT INTO installations (installation_id, ai_url, ai_model, ai_key)
SELECT i, 'https://ai.example.com/v1', 'model-' || i,
       CASE WHEN i % 2 = 0 THEN 'key-' || i END
  FROM generate_series(1, 5) AS i;

INSERT INTO repos (repo, installation_id, duplicates_caught)
SELECT 'org' || (r % 10) || '/repo' || r, 1 + r % 5, r % 7
  FROM generate_series(1, 100) AS r;

INSERT INTO repo_config (repo) SELECT repo FROM repos;

INSERT INTO reviewer_rules (repo, position, pattern)
SELECT repo, p, CASE p WHEN 1 THEN '*' WHEN 2 THEN 'docs/**' ELSE 'tidebot/*.py' END
  FROM repos, generate_series(1, 3) AS p;

INSERT INTO reviewer_rule_owners (repo, position, owner)
SELECT repo, position, 'user' || (position * 7 + o)
  FROM reviewer_rules, generate_series(1, 2) AS o;

INSERT INTO command_stats (repo, command, run_count)
SELECT repo, c, 1 + (random() * 200)::INT
  FROM repos, unnest(ARRAY['help','label','assign','remind','vote','kudos','review','stats']) AS c;

INSERT INTO review_counts (repo, command, review_count)
SELECT repo, c, (random() * 40)::INT
  FROM repos, unnest(ARRAY['review','security','perf']) AS c;

INSERT INTO kudos (repo, login, kudos_count)
SELECT repo, 'user' || u, 1 + (random() * 10)::INT
  FROM repos, generate_series(1, 20) AS u;

-- 10 000 hits spread over the last two hours, so about half of them fall
-- inside the one-hour window the rate limiter counts.
INSERT INTO command_hits (repo, user_login, hit_at)
SELECT 'org' || (r % 10) || '/repo' || r,
       'user' || (1 + (random() * 499)::INT),
       extract(epoch from now()) - random() * 7200 + h * 1e-6
  FROM generate_series(1, 10000) AS h,
       LATERAL (SELECT 1 + (h % 100) AS r) AS pick;

INSERT INTO votes (repo, number, question, opened_by)
SELECT repo, n, 'Merge this?', 'user' || n
  FROM repos, generate_series(1, 2) AS n;

INSERT INTO vote_ballots (repo, number, voter, choice)
SELECT repo, number, 'user' || v,
       (ARRAY['yes','no','abstain'])[1 + (random() * 2)::INT]
  FROM votes, generate_series(1, 10) AS v;

-- 1 000 reminders: most are due in the future, a few are already due.
INSERT INTO reminders (repo, number, author, due_at, text)
SELECT 'org' || (r % 10) || '/repo' || r, 1 + m % 50, 'user' || (1 + m % 500),
       extract(epoch from now()) + (random() * 86400 * 7) - 2000, 'ping'
  FROM generate_series(1, 1000) AS m,
       LATERAL (SELECT 1 + (m % 100) AS r) AS pick;

INSERT INTO queue_waits (repo, wait_seq, wait_seconds)
SELECT repo, s, random() * 30
  FROM repos, generate_series(1, 200) AS s;

INSERT INTO web_sessions (session_id, login, token, expires_at)
SELECT 'sess-' || s, 'user' || s, 'token-' || s, extract(epoch from now()) + 3600
  FROM generate_series(1, 500) AS s;

ANALYZE;
