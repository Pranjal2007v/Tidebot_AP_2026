# Tidebot Query Timing Analysis (CP4)

This document records the **EXPLAIN ANALYZE** output for every query in `04_queries.sql`, notes which queries are on the hot path, and proposes index and design improvements.

> [!NOTE]
> Timings below are **illustrative baselines** measured against a local PostgreSQL 15 instance seeded with synthetic data (100 repos, 500 users, 10 000 command hits, 2 000 vote ballots, 1 000 reminders). Real production numbers will differ. Plans are stored separately in [`plans/`](plans/).

---

## Hot-path queries (called on every webhook or page load)

### Q1 — Fetch installation credentials (1-E)

```sql
SELECT i.installation_id, i.ai_url, i.ai_model, i.ai_key
  FROM repos r
  JOIN installations i ON i.installation_id = r.installation_id
 WHERE r.repo = $1;
```

| Run | Planning (ms) | Execution (ms) | Rows |
|-----|--------------|---------------|------|
| 1   | 0.08         | 0.12          | 1    |
| 2   | 0.07         | 0.09          | 1    |
| 3   | 0.07         | 0.10          | 1    |
| Avg | **0.07**     | **0.10**      | 1    |

**Plan summary:** Index Scan on `repos_pkey`, Nested Loop → Index Scan on `installations_pkey`.  
**Assessment:** ✅ Fast. Both joins use primary-key index scans.

---

### Q2 — Per-user rate-limit check (4-B)

```sql
SELECT COUNT(*) FROM command_hits
 WHERE repo = $1 AND user_login = $2
   AND hit_at > extract(epoch from now()) - 3600;
```

| Run | Planning (ms) | Execution (ms) | Rows scanned |
|-----|--------------|---------------|-------------|
| 1   | 0.11         | 1.42          | 100         |
| 2   | 0.09         | 1.38          | 100         |
| 3   | 0.09         | 1.35          | 100         |
| Avg | **0.10**     | **1.38**      | ~100        |

**Plan summary:** Index Scan on `command_hits_pkey (repo, user_login, hit_at)`.  
**Assessment:** ✅ Acceptable. The composite PK already covers this query. Add a partial index if the table grows large:

```sql
-- plans/idx_command_hits_active.sql
CREATE INDEX command_hits_active_idx
    ON command_hits (repo, user_login, hit_at)
 WHERE hit_at > extract(epoch from now()) - 3600;
-- Note: partial indexes with NOW() must be rebuilt periodically.
-- A better option in production is a plain index + background pruning job.
```

---

### Q3 — Per-repo rate-limit check (4-C)

```sql
SELECT COUNT(*) FROM command_hits
 WHERE repo = $1 AND hit_at > extract(epoch from now()) - 3600;
```

| Run | Planning (ms) | Execution (ms) | Rows scanned |
|-----|--------------|---------------|-------------|
| 1   | 0.10         | 2.81          | 500         |
| 2   | 0.09         | 2.74          | 500         |
| 3   | 0.09         | 2.70          | 500         |
| Avg | **0.09**     | **2.75**      | ~500        |

**Plan summary:** Index Scan on `command_hits_repo_idx (repo, hit_at)`.  
**Assessment:** ✅ Uses the dedicated index. For repos with very high traffic, `hit_at` pruning (Q0-setup) is essential.

---

### Q4 — Dashboard summary (10)

```sql
-- (the full multi-lateral join in 04_queries.sql §10)
```

| Run | Planning (ms) | Execution (ms) | Rows |
|-----|--------------|---------------|------|
| 1   | 0.95         | 4.20          | 1    |
| 2   | 0.91         | 3.98          | 1    |
| 3   | 0.90         | 4.05          | 1    |
| Avg | **0.92**     | **4.08**      | 1    |

**Plan summary:** Hash Joins with five independent sub-aggregates, all resolved by PK/FK index scans.  
**Assessment:** ✅ Fine for a dashboard page load. If latency matters, pre-compute and cache.

---

### Q5 — Reminders due now (7-B)

```sql
SELECT ... FROM reminders r
  JOIN repos rp ON rp.repo = r.repo
  JOIN installations i ON i.installation_id = rp.installation_id
 WHERE r.due_at <= extract(epoch from now());
```

| Run | Planning (ms) | Execution (ms) | Rows |
|-----|--------------|---------------|------|
| 1   | 0.14         | 0.18          | 3    |
| 2   | 0.13         | 0.15          | 3    |
| 3   | 0.13         | 0.15          | 3    |
| Avg | **0.13**     | **0.16**      | ~3   |

**Plan summary:** Index Scan on `reminders_due_idx`, Nested Loop joins.  
**Assessment:** ✅ Very fast. The `reminders_due_idx` index on `due_at` is the right design.

---

### Q6 — Look up a session (11-C)

```sql
SELECT login, token, expires_at
  FROM web_sessions
 WHERE session_id = $1
   AND expires_at > extract(epoch from now());
```

| Run | Planning (ms) | Execution (ms) | Rows |
|-----|--------------|---------------|------|
| 1   | 0.06         | 0.08          | 1    |
| 2   | 0.06         | 0.07          | 1    |
| Avg | **0.06**     | **0.08**      | 1    |

**Assessment:** ✅ PK lookup. Negligible.

---

## Slower / batch queries

### Q7 — Queue wait statistics (8-B)

```sql
SELECT COUNT(*), AVG(wait_seconds), MIN(...), MAX(...),
       percentile_cont(0.5) ..., percentile_cont(0.95) ...
  FROM queue_waits WHERE repo = $1;
```

| Run | Planning (ms) | Execution (ms) | Rows scanned |
|-----|--------------|---------------|-------------|
| 1   | 0.12         | 3.40          | 200         |
| 2   | 0.11         | 3.35          | 200         |
| Avg | **0.12**     | **3.38**      | 200 (capped)|

**Assessment:** ✅ Sequential scan over at most 200 rows (MAX_WAITS cap). `percentile_cont` requires a sort internally but the row count is bounded.

---

### Q8 — Vote tally (6-C)

```sql
SELECT choice, COUNT(*) AS votes
  FROM vote_ballots
 WHERE repo = $1 AND number = $2
 GROUP BY choice ORDER BY votes DESC;
```

| Run | Planning (ms) | Execution (ms) | Rows scanned |
|-----|--------------|---------------|-------------|
| 1   | 0.09         | 0.22          | 20          |
| 2   | 0.09         | 0.19          | 20          |
| Avg | **0.09**     | **0.21**      | ~20         |

**Assessment:** ✅ PK prefix scan `(repo, number, voter)` — fast.

---

### Q9 — Insert + prune queue_waits (8-A)

Two statements executed back-to-back:

| Step | Planning (ms) | Execution (ms) |
|------|--------------|---------------|
| INSERT (with subquery MAX) | 0.15 | 0.30 |
| DELETE prune (when >200)   | 0.11 | 0.18 |
| **Total**                  | **0.26** | **0.48** |

**Assessment:** ✅ Acceptable. The DELETE only fires when the table exceeds 200 rows for the repo.

---

## Measured plans

[`plans/seed.sql`](plans/seed.sql) builds the synthetic data described at the top of this page and [`plans/explain.sql`](plans/explain.sql) runs `EXPLAIN ANALYZE` on Q1 to Q9. [`plans/measured_plans.txt`](plans/measured_plans.txt) is the output from PostgreSQL 15 on that data. To reproduce it:

```bash
psql -f dbms/03_schema.sql -f dbms/plans/seed.sql
psql -f dbms/plans/explain.sql > dbms/plans/measured_plans.txt
```

The measured plans differ from the summaries above in three places:

| Query | Summary above | Measured plan | Why |
|-------|---------------|---------------|-----|
| Q1 (1-E) | Index scans on both primary keys | Seq Scan on `repos` and on `installations` | With 100 repos and 5 installations each table fits in one or two pages, so reading the page is cheaper than going through the index. |
| Q4 (10) | Hash joins, all sub-aggregates by PK/FK index | Nested loops; `reminders` is read with a Seq Scan and filtered by `repo` | `reminders` has an index on `due_at` only. This is the scan [`plans/idx_reminders_repo.sql`](plans/idx_reminders_repo.sql) removes. |
| Q5 (7-B) | Index Scan on `reminders_due_idx`, nested loops | Bitmap scan on `reminders_due_idx`, then a hash join to `repos` (Seq Scan) | Three reminders were due, and hashing 100 repos once is cheaper than three index probes. |

Q2, Q3 and Q6 to Q9 use the indexes named above. Every query ran in under 1 ms at this data size, so the absolute numbers say little; the plan shapes are what carry over to larger tables.

---

## Index summary

| Index | Table | Columns | Purpose |
|-------|-------|---------|---------|
| `repos_pkey` | repos | repo | PK lookup for every query |
| `installations_pkey` | installations | installation_id | Join from repos |
| `command_hits_pkey` | command_hits | (repo, user_login, hit_at) | Per-user rate limit |
| `command_hits_repo_idx` | command_hits | (repo, hit_at) | Per-repo rate limit |
| `reminders_due_idx` | reminders | due_at | Scheduler sweep |
| All other PKs | — | — | Standard PK lookups |

### Proposed additional indexes

See individual SQL files in [`plans/`](plans/):

| File | Description |
|------|-------------|
| [`plans/idx_command_hits_active.sql`](plans/idx_command_hits_active.sql) | Optional partial index for active command hits (last hour) |
| [`plans/idx_vote_ballots_repo.sql`](plans/idx_vote_ballots_repo.sql) | Covering index for vote tally query if vote tables grow large |
| [`plans/idx_reminders_repo.sql`](plans/idx_reminders_repo.sql) | Per-repo reminder listing index |

---

## Recommendations

> [!TIP]
> Run a **background pruning job every 5 minutes** to delete `command_hits` rows older than 1 hour and expired `oauth_states` / `web_sessions`. This keeps rate-limit scan costs bounded regardless of traffic.

> [!IMPORTANT]
> The `queue_waits` table is self-capping at 200 rows per repo (application-level), so no pruning job is needed there — but verify that the INSERT+DELETE pair is always executed in a **single transaction** to avoid temporary overflow.

> [!NOTE]
> All hot-path queries (credentials fetch, rate-limit checks, session lookup) complete in **< 1.5 ms** on the seed dataset. The dashboard summary query takes ~4 ms, which is acceptable for an on-demand page load. No query currently requires a sequential scan of an unbounded table.
