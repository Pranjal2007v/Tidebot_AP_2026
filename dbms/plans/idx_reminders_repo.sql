-- Index: reminders_repo_idx
-- Purpose: Speed up per-repo reminder listing (query 7-E).
--          The scheduler sweep (7-B) already uses reminders_due_idx.
--          This index helps when a maintainer asks "what reminders are
--          set for this repo?" and the reminders table is large.

CREATE INDEX IF NOT EXISTS reminders_repo_number_idx
    ON reminders (repo, number, due_at);
