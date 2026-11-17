-- Index: vote_ballots_repo_idx
-- Purpose: If the votes table grows very large (thousands of historical votes
--          per repo), a covering index on (repo, number) helps the tally
--          query (6-C) avoid scanning unrelated repos.
--
-- The existing PK (repo, number, voter) already provides this prefix scan,
-- so this index is only worth adding if EXPLAIN shows Seq Scans on a large table.

CREATE INDEX IF NOT EXISTS vote_ballots_repo_number_idx
    ON vote_ballots (repo, number);
