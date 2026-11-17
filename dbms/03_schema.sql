-- =============================================================
-- Tidebot relational schema
-- Derived from normalization in 01_normalization.md (BCNF)
-- Target: PostgreSQL 15+
-- =============================================================

-- ---------------------------------------------------------------
-- 1. installations
--    One row per GitHub App installation.
--    ai_key is nullable (public endpoints need no key).
-- ---------------------------------------------------------------
CREATE TABLE installations (
    installation_id BIGINT      PRIMARY KEY,
    ai_url          TEXT        NOT NULL,
    ai_model        TEXT        NOT NULL,
    ai_key          TEXT                        -- NULL = public endpoint
);

-- ---------------------------------------------------------------
-- 2. repos
--    One row per GitHub repo known to the bot.
--    installation_id is nullable: a repo can be referenced in
--    state before its installation webhook fires.
-- ---------------------------------------------------------------
CREATE TABLE repos (
    repo                TEXT    PRIMARY KEY,    -- "owner/name", lowercase
    installation_id     BIGINT  REFERENCES installations (installation_id)
                                ON DELETE SET NULL,
    duplicates_caught   INT     NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------
-- 3. repo_config
--    One row per repo – mirrors .tide.yml feature flags.
--    Shares the same PK as repos (1-to-1).
-- ---------------------------------------------------------------
CREATE TABLE repo_config (
    repo            TEXT    PRIMARY KEY REFERENCES repos (repo) ON DELETE CASCADE,
    auto_label      BOOL    NOT NULL DEFAULT TRUE,
    size_labels     BOOL    NOT NULL DEFAULT TRUE,
    star_gate       BOOL    NOT NULL DEFAULT FALSE,
    triage_label    BOOL    NOT NULL DEFAULT TRUE,
    pr_lint         BOOL    NOT NULL DEFAULT TRUE,
    duplicate_check BOOL    NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------
-- 4. reviewer_rules
--    One row per CODEOWNERS-style glob pattern in a repo.
--    position controls evaluation order (last match wins).
-- ---------------------------------------------------------------
CREATE TABLE reviewer_rules (
    repo        TEXT    NOT NULL REFERENCES repos (repo) ON DELETE CASCADE,
    position    INT     NOT NULL,       -- 1-based; last matching rule wins
    pattern     TEXT    NOT NULL,
    PRIMARY KEY (repo, position)
);

-- ---------------------------------------------------------------
-- 5. reviewer_rule_owners
--    Many owners/teams per rule.
-- ---------------------------------------------------------------
CREATE TABLE reviewer_rule_owners (
    repo        TEXT    NOT NULL,
    position    INT     NOT NULL,
    owner       TEXT    NOT NULL,       -- GitHub login or @org/team
    PRIMARY KEY (repo, position, owner),
    FOREIGN KEY (repo, position) REFERENCES reviewer_rules (repo, position)
        ON DELETE CASCADE
);

-- ---------------------------------------------------------------
-- 6. command_stats
--    Running count of every command run per repo.
--    (The bot increments this counter; no log of individual runs.)
-- ---------------------------------------------------------------
CREATE TABLE command_stats (
    repo        TEXT    NOT NULL REFERENCES repos (repo) ON DELETE CASCADE,
    command     TEXT    NOT NULL,
    run_count   INT     NOT NULL DEFAULT 0,
    PRIMARY KEY (repo, command)
);

-- ---------------------------------------------------------------
-- 7. kudos
--    Running count of kudos given to each user per repo.
-- ---------------------------------------------------------------
CREATE TABLE kudos (
    repo        TEXT    NOT NULL REFERENCES repos (repo) ON DELETE CASCADE,
    login       TEXT    NOT NULL,       -- lowercase GitHub login
    kudos_count INT     NOT NULL DEFAULT 0,
    PRIMARY KEY (repo, login)
);

-- ---------------------------------------------------------------
-- 8. votes
--    One row per open (or closed) vote on an issue/PR.
--    At most one active vote per (repo, number) at a time
--    (enforced by the application).
-- ---------------------------------------------------------------
CREATE TABLE votes (
    repo        TEXT    NOT NULL REFERENCES repos (repo) ON DELETE CASCADE,
    number      INT     NOT NULL,       -- issue / PR number
    question    TEXT    NOT NULL,
    opened_by   TEXT    NOT NULL,       -- lowercase login
    PRIMARY KEY (repo, number)
);

-- ---------------------------------------------------------------
-- 9. vote_ballots
--    One row per voter per vote.  A voter can change their answer
--    (application does an UPSERT on (repo, number, voter)).
-- ---------------------------------------------------------------
CREATE TABLE vote_ballots (
    repo    TEXT    NOT NULL,
    number  INT     NOT NULL,
    voter   TEXT    NOT NULL,       -- lowercase login
    choice  TEXT    NOT NULL,       -- e.g. 'yes' | 'no' | 'abstain'
    PRIMARY KEY (repo, number, voter),
    FOREIGN KEY (repo, number) REFERENCES votes (repo, number) ON DELETE CASCADE
);

-- ---------------------------------------------------------------
-- 10. reminders
--     One row per scheduled reminder.  reminder_id is a surrogate
--     key because two identical reminders are legally distinct.
--     installation_id is NOT stored here (3NF fix: derive it via
--     repos → installations when the reminder fires).
-- ---------------------------------------------------------------
CREATE TABLE reminders (
    reminder_id BIGSERIAL   PRIMARY KEY,
    repo        TEXT        NOT NULL REFERENCES repos (repo) ON DELETE CASCADE,
    number      INT         NOT NULL,       -- issue / PR number
    author      TEXT        NOT NULL,       -- who set the reminder
    due_at      DOUBLE PRECISION NOT NULL,  -- Unix timestamp
    text        TEXT        NOT NULL
);

CREATE INDEX reminders_due_idx ON reminders (due_at);

-- ---------------------------------------------------------------
-- 11. command_hits
--     One row per allowed command invocation (used by rate limiter).
--     Rows older than 1 hour can be pruned by a maintenance job.
--     The composite PK handles the (unlikely) case of a user
--     triggering two commands at the exact same float second:
--     the application should use clock_timestamp(), not now().
-- ---------------------------------------------------------------
CREATE TABLE command_hits (
    repo        TEXT            NOT NULL REFERENCES repos (repo) ON DELETE CASCADE,
    user_login  TEXT            NOT NULL,
    hit_at      DOUBLE PRECISION NOT NULL,   -- Unix timestamp
    PRIMARY KEY (repo, user_login, hit_at)
);

CREATE INDEX command_hits_repo_idx ON command_hits (repo, hit_at);

-- ---------------------------------------------------------------
-- 12. queue_waits
--     One row per measured AI-queue wait (capped at MAX_WAITS=200
--     per repo in metrics.py).  wait_seq preserves insertion order.
-- ---------------------------------------------------------------
CREATE TABLE queue_waits (
    repo            TEXT    NOT NULL REFERENCES repos (repo) ON DELETE CASCADE,
    wait_seq        INT     NOT NULL,
    wait_seconds    DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (repo, wait_seq)
);

-- ---------------------------------------------------------------
-- 13. review_counts
--     Running count of each review-type command per repo.
-- ---------------------------------------------------------------
CREATE TABLE review_counts (
    repo            TEXT    NOT NULL REFERENCES repos (repo) ON DELETE CASCADE,
    command         TEXT    NOT NULL,   -- e.g. 'review', 'security', 'perf'
    review_count    INT     NOT NULL DEFAULT 0,
    PRIMARY KEY (repo, command)
);

-- ---------------------------------------------------------------
-- Memory-only tables
-- These exist only in RAM (signin.py) and are recreated empty on
-- every restart.  They are included here so the full schema is
-- self-contained; create them in a separate migration or omit
-- them if the bot continues to manage them in memory.
-- ---------------------------------------------------------------

CREATE TABLE web_sessions (
    session_id  TEXT            PRIMARY KEY,
    login       TEXT            NOT NULL,   -- lowercase GitHub login
    token       TEXT            NOT NULL,   -- OAuth access token
    expires_at  DOUBLE PRECISION NOT NULL   -- Unix timestamp
);

CREATE TABLE session_push_access (
    session_id  TEXT    NOT NULL REFERENCES web_sessions (session_id) ON DELETE CASCADE,
    repo        TEXT    NOT NULL,
    can_push    BOOL    NOT NULL,
    PRIMARY KEY (session_id, repo)
);

CREATE TABLE oauth_states (
    state       TEXT            PRIMARY KEY,
    return_to   TEXT            NOT NULL,
    expires_at  DOUBLE PRECISION NOT NULL
);

-- =============================================================
-- Useful derived-value queries (see 01_normalization.md §3)
-- =============================================================

-- Total commands run for a repo
-- SELECT SUM(run_count) FROM command_stats WHERE repo = $1;

-- Per-user rate-limit check (commands in last hour)
-- SELECT COUNT(*) FROM command_hits
--   WHERE repo = $1 AND user_login = $2 AND hit_at > extract(epoch from now()) - 3600;

-- Per-repo rate-limit check
-- SELECT COUNT(*) FROM command_hits
--   WHERE repo = $1 AND hit_at > extract(epoch from now()) - 3600;

-- Vote tally
-- SELECT choice, COUNT(*) AS votes FROM vote_ballots
--   WHERE repo = $1 AND number = $2 GROUP BY choice;

-- Median and max queue wait for a repo
-- SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY wait_seconds) AS median_wait,
--        MAX(wait_seconds) AS max_wait
--   FROM queue_waits WHERE repo = $1;
