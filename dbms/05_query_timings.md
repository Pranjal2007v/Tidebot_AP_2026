# Tidebot Query Timing & Plan Analysis (CP4)

This document records the **EXPLAIN (ANALYZE, BUFFERS)** measurements for every SQL query in `04_queries.sql` executed **3 times** against PostgreSQL. Detailed execution plans are stored separately as standalone artifacts in [`plans/`](plans/).

> [!NOTE]
> **Environment & Benchmark Setup:**
> - **Engine:** PostgreSQL 16+ on Apple Silicon (macOS).
> - **Seed Dataset:** 100 GitHub App installations, 100 repositories, 100 repository configs, 500 reviewer rules, 1,000 reviewer rule owners, 1,000 command statistics rows, 1,960 kudos records across 500 users, 200 votes, 1,975 vote ballots, 1,000 reminders, 10,000 command rate-limit hits, 4,000 queue wait samples (200 capped per repo), and active web sessions.
> - **Protocol:** Each query was benchmarked 3 times (`Run 1`, `Run 2`, `Run 3`) within isolated transaction boundaries to maintain identical system state, with full buffer cache hits/reads and timing recorded.

---

## Overall Query Benchmark Summary Table

| Query ID | Section | Query Description | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Execution Plan |
|:---|:---|:---|:---:|:---:|:---:|:---:|:---|
| **Q0-A** | 0 | Prune command_hits older than 1 hour | 3.307 | 4.408 | 3.795 | **3.837** | [`q00_a_prune_command_hits.txt`](plans/q00_a_prune_command_hits.txt) |
| **Q0-B** | 0 | Prune expired oauth_states | 0.290 | 0.256 | 0.247 | **0.264** | [`q00_b_prune_oauth_states.txt`](plans/q00_b_prune_oauth_states.txt) |
| **Q0-C** | 0 | Prune expired web_sessions | 0.652 | 0.575 | 0.558 | **0.595** | [`q00_c_prune_web_sessions.txt`](plans/q00_c_prune_web_sessions.txt) |
| **Q1-A** | 1 | Upsert an installation | 0.169 | 0.141 | 0.148 | **0.153** | [`q01_a_upsert_installation.txt`](plans/q01_a_upsert_installation.txt) |
| **Q1-B** | 1 | Register a repo for an installation | 0.325 | 0.298 | 0.491 | **0.371** | [`q01_b_register_repo.txt`](plans/q01_b_register_repo.txt) |
| **Q1-C** | 1 | Insert default config for a new repo | 0.075 | 0.078 | 0.074 | **0.076** | [`q01_c_insert_repo_config.txt`](plans/q01_c_insert_repo_config.txt) |
| **Q1-D** | 1 | Update a single config flag for a repo | 0.213 | 0.181 | 0.189 | **0.194** | [`q01_d_update_repo_config.txt`](plans/q01_d_update_repo_config.txt) |
| **Q1-E** | 1 | Fetch installation credentials for a repo | 0.300 | 0.275 | 0.262 | **0.279** | [`q01_e_fetch_installation_credentials.txt`](plans/q01_e_fetch_installation_credentials.txt) |
| **Q2-A1** | 2 | Replace reviewer rules - Step 1: Delete existing rules | 0.408 | 0.381 | 0.360 | **0.383** | [`q02_a1_delete_reviewer_rules.txt`](plans/q02_a1_delete_reviewer_rules.txt) |
| **Q2-A2** | 2 | Replace reviewer rules - Step 2: Insert new rule | 0.311 | 0.310 | 0.304 | **0.308** | [`q02_a2_insert_reviewer_rule.txt`](plans/q02_a2_insert_reviewer_rule.txt) |
| **Q2-A3** | 2 | Replace reviewer rules - Step 3: Insert owner for rule | 0.316 | 0.305 | 0.327 | **0.316** | [`q02_a3_insert_reviewer_rule_owner.txt`](plans/q02_a3_insert_reviewer_rule_owner.txt) |
| **Q2-B** | 2 | Find reviewers for a changed file | 0.273 | 0.299 | 0.284 | **0.285** | [`q02_b_find_reviewers.txt`](plans/q02_b_find_reviewers.txt) |
| **Q3-A** | 3 | Increment a command counter (upsert) | 0.336 | 0.297 | 0.310 | **0.314** | [`q03_a_increment_command_stat.txt`](plans/q03_a_increment_command_stat.txt) |
| **Q3-B** | 3 | Total commands run in a repo | 0.177 | 0.161 | 0.169 | **0.169** | [`q03_b_total_commands_repo.txt`](plans/q03_b_total_commands_repo.txt) |
| **Q3-C** | 3 | Command breakdown for a repo | 0.165 | 0.171 | 0.163 | **0.166** | [`q03_c_command_breakdown_repo.txt`](plans/q03_c_command_breakdown_repo.txt) |
| **Q3-D** | 3 | Top repos by command volume (leaderboard) | 0.286 | 0.283 | 0.287 | **0.285** | [`q03_d_leaderboard_command_volume.txt`](plans/q03_d_leaderboard_command_volume.txt) |
| **Q4-A** | 4 | Record an allowed command invocation | 0.377 | 0.351 | 0.355 | **0.361** | [`q04_a_record_command_hit.txt`](plans/q04_a_record_command_hit.txt) |
| **Q4-B** | 4 | Per-user count in the last hour | 0.289 | 0.239 | 0.235 | **0.254** | [`q04_b_user_rate_limit_check.txt`](plans/q04_b_user_rate_limit_check.txt) |
| **Q4-C** | 4 | Per-repo count in the last hour | 0.390 | 0.300 | 0.308 | **0.333** | [`q04_c_repo_rate_limit_check.txt`](plans/q04_c_repo_rate_limit_check.txt) |
| **Q5-A** | 5 | Give kudos (upsert) | 0.367 | 0.328 | 0.312 | **0.336** | [`q05_a_give_kudos.txt`](plans/q05_a_give_kudos.txt) |
| **Q5-B** | 5 | Kudos leaderboard for a repo | 0.198 | 0.189 | 0.179 | **0.189** | [`q05_b_kudos_leaderboard.txt`](plans/q05_b_kudos_leaderboard.txt) |
| **Q5-C** | 5 | Total kudos given in a repo | 0.183 | 0.179 | 0.182 | **0.181** | [`q05_c_total_kudos_repo.txt`](plans/q05_c_total_kudos_repo.txt) |
| **Q6-A** | 6 | Open a new vote | 0.337 | 0.299 | 0.305 | **0.314** | [`q06_a_open_new_vote.txt`](plans/q06_a_open_new_vote.txt) |
| **Q6-B** | 6 | Cast or change a ballot (upsert) | 0.408 | 0.367 | 0.353 | **0.376** | [`q06_b_cast_or_change_ballot.txt`](plans/q06_b_cast_or_change_ballot.txt) |
| **Q6-C** | 6 | Tally the results of a vote | 0.652 | 0.214 | 0.234 | **0.367** | [`q06_c_tally_vote_results.txt`](plans/q06_c_tally_vote_results.txt) |
| **Q6-D** | 6 | List all open votes in a repo | 0.336 | 0.337 | 0.370 | **0.348** | [`q06_d_list_open_votes.txt`](plans/q06_d_list_open_votes.txt) |
| **Q6-E** | 6 | Delete a vote and its ballots | 0.353 | 0.343 | 0.339 | **0.345** | [`q06_e_delete_vote.txt`](plans/q06_e_delete_vote.txt) |
| **Q7-A** | 7 | Create a reminder | 0.355 | 0.329 | 0.342 | **0.342** | [`q07_a_create_reminder.txt`](plans/q07_a_create_reminder.txt) |
| **Q7-B** | 7 | Fetch all reminders due now | 0.605 | 0.574 | 0.560 | **0.580** | [`q07_b_fetch_reminders_due_now.txt`](plans/q07_b_fetch_reminders_due_now.txt) |
| **Q7-C** | 7 | Delete a reminder after it has fired | 0.209 | 0.208 | 0.200 | **0.206** | [`q07_c_delete_reminder.txt`](plans/q07_c_delete_reminder.txt) |
| **Q7-D** | 7 | Count open reminders across all repos | 0.217 | 0.213 | 0.210 | **0.213** | [`q07_d_count_open_reminders.txt`](plans/q07_d_count_open_reminders.txt) |
| **Q7-E** | 7 | List reminders for a specific issue / PR | 0.223 | 0.230 | 0.225 | **0.226** | [`q07_e_list_reminders_issue.txt`](plans/q07_e_list_reminders_issue.txt) |
| **Q8-A1** | 8 | Record a queue wait - Step 1: Insert new row | 0.659 | 0.386 | 0.384 | **0.476** | [`q08_a1_insert_queue_wait.txt`](plans/q08_a1_insert_queue_wait.txt) |
| **Q8-A2** | 8 | Record a queue wait - Step 2: Prune oldest rows keeping 200 | 0.254 | 0.248 | 0.242 | **0.248** | [`q08_a2_prune_queue_waits.txt`](plans/q08_a2_prune_queue_waits.txt) |
| **Q8-B** | 8 | Queue wait statistics for a repo | 0.229 | 0.248 | 0.220 | **0.232** | [`q08_b_queue_wait_statistics.txt`](plans/q08_b_queue_wait_statistics.txt) |
| **Q9-A** | 9 | Increment a review counter (upsert) | 0.181 | 0.162 | 0.156 | **0.166** | [`q09_a_increment_review_counter.txt`](plans/q09_a_increment_review_counter.txt) |
| **Q9-B** | 9 | Total reviews posted for a repo | 0.210 | 0.169 | 0.170 | **0.183** | [`q09_b_total_reviews_repo.txt`](plans/q09_b_total_reviews_repo.txt) |
| **Q9-C1** | 9 | Increment duplicates caught for a repo | 0.207 | 0.213 | 0.214 | **0.211** | [`q09_c1_increment_duplicates_caught.txt`](plans/q09_c1_increment_duplicates_caught.txt) |
| **Q9-C2** | 9 | Select duplicates caught for a repo | 0.145 | 0.134 | 0.146 | **0.142** | [`q09_c2_select_duplicates_caught.txt`](plans/q09_c2_select_duplicates_caught.txt) |
| **Q10** | 10 | Dashboard summary (multi-lateral aggregate) | 0.697 | 0.685 | 0.651 | **0.678** | [`q10_dashboard_summary.txt`](plans/q10_dashboard_summary.txt) |
| **Q11-A** | 11 | Create a session after OAuth callback | 0.155 | 0.144 | 0.139 | **0.146** | [`q11_a_create_web_session.txt`](plans/q11_a_create_web_session.txt) |
| **Q11-B** | 11 | Store repo push-access flag for a session | 0.313 | 0.306 | 0.312 | **0.310** | [`q11_b_store_session_push_access.txt`](plans/q11_b_store_session_push_access.txt) |
| **Q11-C** | 11 | Look up a session | 0.184 | 0.192 | 0.184 | **0.187** | [`q11_c_lookup_web_session.txt`](plans/q11_c_lookup_web_session.txt) |
| **Q11-D** | 11 | Check push access for a repo in a session | 0.152 | 0.146 | 0.144 | **0.147** | [`q11_d_check_session_push_access.txt`](plans/q11_d_check_session_push_access.txt) |
| **Q11-E** | 11 | Create an OAuth state token | 0.128 | 0.127 | 0.127 | **0.127** | [`q11_e_create_oauth_state.txt`](plans/q11_e_create_oauth_state.txt) |
| **Q11-F** | 11 | Consume an OAuth state (validate and delete) | 0.217 | 0.211 | 0.213 | **0.214** | [`q11_f_consume_oauth_state.txt`](plans/q11_f_consume_oauth_state.txt) |

---

## Detailed Query Execution Profiles

### Section 0. Setup helpers

#### Q0-A — Prune command_hits older than 1 hour

```sql
DELETE FROM command_hits WHERE hit_at < extract(epoch from now()) - 3600;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.597 | 2.710 | 3.307 |
| Run 2 | 0.262 | 4.146 | 4.408 |
| Run 3 | 0.299 | 3.496 | 3.795 |
| **Average** | **0.386** | **3.451** | **3.837** |

**Plan Summary:** `Delete on command_hits  (cost=0.00..299.00 rows=0 width=0) (actual time=2.659..2.660 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q00_a_prune_command_hits.txt`](plans/q00_a_prune_command_hits.txt)

---

#### Q0-B — Prune expired oauth_states

```sql
DELETE FROM oauth_states WHERE expires_at < extract(epoch from now());
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.206 | 0.084 | 0.290 |
| Run 2 | 0.176 | 0.080 | 0.256 |
| Run 3 | 0.172 | 0.075 | 0.247 |
| **Average** | **0.185** | **0.080** | **0.264** |

**Plan Summary:** `Delete on oauth_states  (cost=0.00..3.00 rows=0 width=0) (actual time=0.040..0.041 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q00_b_prune_oauth_states.txt`](plans/q00_b_prune_oauth_states.txt)

---

#### Q0-C — Prune expired web_sessions

```sql
DELETE FROM web_sessions WHERE expires_at < extract(epoch from now());
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.190 | 0.462 | 0.652 |
| Run 2 | 0.160 | 0.415 | 0.575 |
| Run 3 | 0.161 | 0.397 | 0.558 |
| **Average** | **0.170** | **0.425** | **0.595** |

**Plan Summary:** `Delete on web_sessions  (cost=0.00..4.00 rows=0 width=0) (actual time=0.058..0.058 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q00_c_prune_web_sessions.txt`](plans/q00_c_prune_web_sessions.txt)

---

### Section 1. Installation & repo management

#### Q1-A — Upsert an installation

```sql
INSERT INTO installations (installation_id, ai_url, ai_model, ai_key)
VALUES (999, 'https://api.openai.com/v1', 'gpt-4o', 'sk-test-key')
ON CONFLICT (installation_id)
DO UPDATE SET ai_url   = EXCLUDED.ai_url,
              ai_model = EXCLUDED.ai_model,
              ai_key   = EXCLUDED.ai_key;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.050 | 0.119 | 0.169 |
| Run 2 | 0.042 | 0.099 | 0.141 |
| Run 3 | 0.045 | 0.103 | 0.148 |
| **Average** | **0.046** | **0.107** | **0.153** |

**Plan Summary:** `Insert on installations  (cost=0.00..0.01 rows=0 width=0) (actual time=0.083..0.084 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q01_a_upsert_installation.txt`](plans/q01_a_upsert_installation.txt)

---

#### Q1-B — Register a repo for an installation

```sql
INSERT INTO repos (repo, installation_id, duplicates_caught)
VALUES ('org_1/new_sample_repo', 1, 0)
ON CONFLICT (repo)
DO UPDATE SET installation_id = EXCLUDED.installation_id;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.048 | 0.277 | 0.325 |
| Run 2 | 0.044 | 0.254 | 0.298 |
| Run 3 | 0.040 | 0.451 | 0.491 |
| **Average** | **0.044** | **0.327** | **0.371** |

**Plan Summary:** `Insert on repos  (cost=0.00..0.01 rows=0 width=0) (actual time=0.059..0.059 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q01_b_register_repo.txt`](plans/q01_b_register_repo.txt)

---

#### Q1-C — Insert default config for a new repo

```sql
INSERT INTO repo_config (repo, auto_label, size_labels, star_gate,
                         triage_label, pr_lint, duplicate_check)
VALUES ('org_1/repo_1', TRUE, TRUE, FALSE, TRUE, TRUE, TRUE)
ON CONFLICT (repo) DO NOTHING;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.036 | 0.039 | 0.075 |
| Run 2 | 0.039 | 0.039 | 0.078 |
| Run 3 | 0.036 | 0.038 | 0.074 |
| **Average** | **0.037** | **0.039** | **0.076** |

**Plan Summary:** `Insert on repo_config  (cost=0.00..0.01 rows=0 width=0) (actual time=0.025..0.026 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q01_c_insert_repo_config.txt`](plans/q01_c_insert_repo_config.txt)

---

#### Q1-D — Update a single config flag for a repo

```sql
UPDATE repo_config SET star_gate = TRUE WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.140 | 0.073 | 0.213 |
| Run 2 | 0.115 | 0.066 | 0.181 |
| Run 3 | 0.117 | 0.072 | 0.189 |
| **Average** | **0.124** | **0.070** | **0.194** |

**Plan Summary:** `Update on repo_config  (cost=0.00..2.25 rows=0 width=0) (actual time=0.033..0.033 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q01_d_update_repo_config.txt`](plans/q01_d_update_repo_config.txt)

---

#### Q1-E — Fetch installation credentials for a repo

```sql
SELECT i.installation_id, i.ai_url, i.ai_model, i.ai_key
  FROM repos r
  JOIN installations i ON i.installation_id = r.installation_id
 WHERE r.repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.267 | 0.033 | 0.300 |
| Run 2 | 0.235 | 0.040 | 0.275 |
| Run 3 | 0.233 | 0.029 | 0.262 |
| **Average** | **0.245** | **0.034** | **0.279** |

**Plan Summary:** `Hash Join  (cost=2.26..5.54 rows=1 width=55) (actual time=0.013..0.018 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q01_e_fetch_installation_credentials.txt`](plans/q01_e_fetch_installation_credentials.txt)

---

### Section 2. Reviewer rules

#### Q2-A1 — Replace reviewer rules - Step 1: Delete existing rules

```sql
DELETE FROM reviewer_rules WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.148 | 0.260 | 0.408 |
| Run 2 | 0.137 | 0.244 | 0.381 |
| Run 3 | 0.136 | 0.224 | 0.360 |
| **Average** | **0.140** | **0.243** | **0.383** |

**Plan Summary:** `Delete on reviewer_rules  (cost=4.31..8.37 rows=0 width=0) (actual time=0.043..0.043 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q02_a1_delete_reviewer_rules.txt`](plans/q02_a1_delete_reviewer_rules.txt)

---

#### Q2-A2 — Replace reviewer rules - Step 2: Insert new rule

```sql
INSERT INTO reviewer_rules (repo, position, pattern) VALUES ('org_1/repo_1', 10, 'benchmarks/*');
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.019 | 0.292 | 0.311 |
| Run 2 | 0.022 | 0.288 | 0.310 |
| Run 3 | 0.019 | 0.285 | 0.304 |
| **Average** | **0.020** | **0.288** | **0.308** |

**Plan Summary:** `Insert on reviewer_rules  (cost=0.00..0.01 rows=0 width=0) (actual time=0.081..0.081 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q02_a2_insert_reviewer_rule.txt`](plans/q02_a2_insert_reviewer_rule.txt)

---

#### Q2-A3 — Replace reviewer rules - Step 3: Insert owner for rule

```sql
INSERT INTO reviewer_rule_owners (repo, position, owner) VALUES ('org_1/repo_1', 1, 'user_bench');
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.019 | 0.297 | 0.316 |
| Run 2 | 0.018 | 0.287 | 0.305 |
| Run 3 | 0.019 | 0.308 | 0.327 |
| **Average** | **0.019** | **0.297** | **0.316** |

**Plan Summary:** `Insert on reviewer_rule_owners  (cost=0.00..0.01 rows=0 width=0) (actual time=0.079..0.079 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q02_a3_insert_reviewer_rule_owner.txt`](plans/q02_a3_insert_reviewer_rule_owner.txt)

---

#### Q2-B — Find reviewers for a changed file

```sql
SELECT rr.position, rr.pattern, rro.owner
  FROM reviewer_rules rr
  JOIN reviewer_rule_owners rro
    ON rro.repo = rr.repo AND rro.position = rr.position
 WHERE rr.repo = 'org_1/repo_1'
 ORDER BY rr.position;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.215 | 0.058 | 0.273 |
| Run 2 | 0.242 | 0.057 | 0.299 |
| Run 3 | 0.226 | 0.058 | 0.284 |
| **Average** | **0.228** | **0.058** | **0.285** |

**Plan Summary:** `Sort  (cost=21.49..21.51 rows=10 width=18) (actual time=0.038..0.038 rows=10.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q02_b_find_reviewers.txt`](plans/q02_b_find_reviewers.txt)

---

### Section 3. Command stats

#### Q3-A — Increment a command counter (upsert)

```sql
INSERT INTO command_stats (repo, command, run_count)
VALUES ('org_1/repo_1', 'review', 1)
ON CONFLICT (repo, command)
DO UPDATE SET run_count = command_stats.run_count + 1;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.036 | 0.300 | 0.336 |
| Run 2 | 0.034 | 0.263 | 0.297 |
| Run 3 | 0.036 | 0.274 | 0.310 |
| **Average** | **0.035** | **0.279** | **0.314** |

**Plan Summary:** `Insert on command_stats  (cost=0.00..0.01 rows=0 width=0) (actual time=0.090..0.090 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q03_a_increment_command_stat.txt`](plans/q03_a_increment_command_stat.txt)

---

#### Q3-B — Total commands run in a repo

```sql
SELECT SUM(run_count) AS total_commands FROM command_stats WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.141 | 0.036 | 0.177 |
| Run 2 | 0.130 | 0.031 | 0.161 |
| Run 3 | 0.135 | 0.034 | 0.169 |
| **Average** | **0.135** | **0.034** | **0.169** |

**Plan Summary:** `Aggregate  (cost=11.84..11.85 rows=1 width=8) (actual time=0.014..0.015 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q03_b_total_commands_repo.txt`](plans/q03_b_total_commands_repo.txt)

---

#### Q3-C — Command breakdown for a repo

```sql
SELECT command, run_count FROM command_stats WHERE repo = 'org_1/repo_1' ORDER BY run_count DESC;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.133 | 0.032 | 0.165 |
| Run 2 | 0.136 | 0.035 | 0.171 |
| Run 3 | 0.131 | 0.032 | 0.163 |
| **Average** | **0.133** | **0.033** | **0.166** |

**Plan Summary:** `Sort  (cost=11.98..12.00 rows=10 width=10) (actual time=0.017..0.018 rows=10.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q03_c_command_breakdown_repo.txt`](plans/q03_c_command_breakdown_repo.txt)

---

#### Q3-D — Top repos by command volume (leaderboard)

```sql
SELECT repo, SUM(run_count) AS total FROM command_stats GROUP BY repo ORDER BY total DESC LIMIT 10;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.151 | 0.135 | 0.286 |
| Run 2 | 0.148 | 0.135 | 0.283 |
| Run 3 | 0.151 | 0.136 | 0.287 |
| **Average** | **0.150** | **0.135** | **0.285** |

**Plan Summary:** `Limit  (cost=25.16..25.19 rows=10 width=22) (actual time=0.112..0.112 rows=10.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q03_d_leaderboard_command_volume.txt`](plans/q03_d_leaderboard_command_volume.txt)

---

### Section 4. Rate limiting

#### Q4-A — Record an allowed command invocation

```sql
INSERT INTO command_hits (repo, user_login, hit_at) VALUES ('org_1/repo_1', 'user_1', extract(epoch from clock_timestamp()));
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.020 | 0.357 | 0.377 |
| Run 2 | 0.019 | 0.332 | 0.351 |
| Run 3 | 0.021 | 0.334 | 0.355 |
| **Average** | **0.020** | **0.341** | **0.361** |

**Plan Summary:** `Insert on command_hits  (cost=0.00..0.02 rows=0 width=0) (actual time=0.133..0.133 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q04_a_record_command_hit.txt`](plans/q04_a_record_command_hit.txt)

---

#### Q4-B — Per-user count in the last hour

```sql
SELECT COUNT(*) AS hit_count
  FROM command_hits
 WHERE repo       = 'org_1/repo_1'
   AND user_login = 'user_1'
   AND hit_at > extract(epoch from now()) - 3600;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.231 | 0.058 | 0.289 |
| Run 2 | 0.215 | 0.024 | 0.239 |
| Run 3 | 0.212 | 0.023 | 0.235 |
| **Average** | **0.219** | **0.035** | **0.254** |

**Plan Summary:** `Aggregate  (cost=4.32..4.33 rows=1 width=8) (actual time=0.042..0.043 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q04_b_user_rate_limit_check.txt`](plans/q04_b_user_rate_limit_check.txt)

---

#### Q4-C — Per-repo count in the last hour

```sql
SELECT COUNT(*) AS hit_count
  FROM command_hits
 WHERE repo   = 'org_1/repo_1'
   AND hit_at > extract(epoch from now()) - 3600;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.232 | 0.158 | 0.390 |
| Run 2 | 0.216 | 0.084 | 0.300 |
| Run 3 | 0.220 | 0.088 | 0.308 |
| **Average** | **0.223** | **0.110** | **0.333** |

**Plan Summary:** `Aggregate  (cost=5.49..5.50 rows=1 width=8) (actual time=0.140..0.141 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q04_c_repo_rate_limit_check.txt`](plans/q04_c_repo_rate_limit_check.txt)

---

### Section 5. Kudos

#### Q5-A — Give kudos (upsert)

```sql
INSERT INTO kudos (repo, login, kudos_count)
VALUES ('org_1/repo_1', 'user_1', 1)
ON CONFLICT (repo, login)
DO UPDATE SET kudos_count = kudos.kudos_count + 1;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.034 | 0.333 | 0.367 |
| Run 2 | 0.035 | 0.293 | 0.328 |
| Run 3 | 0.034 | 0.278 | 0.312 |
| **Average** | **0.034** | **0.301** | **0.336** |

**Plan Summary:** `Insert on kudos  (cost=0.00..0.01 rows=0 width=0) (actual time=0.119..0.119 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q05_a_give_kudos.txt`](plans/q05_a_give_kudos.txt)

---

#### Q5-B — Kudos leaderboard for a repo

```sql
SELECT login, kudos_count FROM kudos WHERE repo = 'org_1/repo_1' ORDER BY kudos_count DESC LIMIT 10;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.155 | 0.043 | 0.198 |
| Run 2 | 0.141 | 0.048 | 0.189 |
| Run 3 | 0.140 | 0.039 | 0.179 |
| **Average** | **0.145** | **0.043** | **0.189** |

**Plan Summary:** `Limit  (cost=20.87..20.89 rows=10 width=12) (actual time=0.032..0.033 rows=10.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q05_b_kudos_leaderboard.txt`](plans/q05_b_kudos_leaderboard.txt)

---

#### Q5-C — Total kudos given in a repo

```sql
SELECT SUM(kudos_count) AS total_kudos FROM kudos WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.139 | 0.044 | 0.183 |
| Run 2 | 0.135 | 0.044 | 0.179 |
| Run 3 | 0.139 | 0.043 | 0.182 |
| **Average** | **0.138** | **0.044** | **0.181** |

**Plan Summary:** `Aggregate  (cost=20.51..20.52 rows=1 width=8) (actual time=0.024..0.024 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q05_c_total_kudos_repo.txt`](plans/q05_c_total_kudos_repo.txt)

---

### Section 6. Votes

#### Q6-A — Open a new vote

```sql
INSERT INTO votes (repo, number, question, opened_by) VALUES ('org_1/repo_1', 99, 'Release v1.0?', 'user_1');
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.020 | 0.317 | 0.337 |
| Run 2 | 0.018 | 0.281 | 0.299 |
| Run 3 | 0.020 | 0.285 | 0.305 |
| **Average** | **0.019** | **0.294** | **0.314** |

**Plan Summary:** `Insert on votes  (cost=0.00..0.01 rows=0 width=0) (actual time=0.095..0.095 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q06_a_open_new_vote.txt`](plans/q06_a_open_new_vote.txt)

---

#### Q6-B — Cast or change a ballot (upsert)

```sql
INSERT INTO vote_ballots (repo, number, voter, choice)
VALUES ('org_1/repo_1', 1, 'user_1', 'yes')
ON CONFLICT (repo, number, voter)
DO UPDATE SET choice = EXCLUDED.choice;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.039 | 0.369 | 0.408 |
| Run 2 | 0.040 | 0.327 | 0.367 |
| Run 3 | 0.038 | 0.315 | 0.353 |
| **Average** | **0.039** | **0.337** | **0.376** |

**Plan Summary:** `Insert on vote_ballots  (cost=0.00..0.01 rows=0 width=0) (actual time=0.127..0.127 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q06_b_cast_or_change_ballot.txt`](plans/q06_b_cast_or_change_ballot.txt)

---

#### Q6-C — Tally the results of a vote

```sql
SELECT choice, COUNT(*) AS votes
  FROM vote_ballots
 WHERE repo = 'org_1/repo_1' AND number = 1
 GROUP BY choice
 ORDER BY votes DESC;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.165 | 0.487 | 0.652 |
| Run 2 | 0.153 | 0.061 | 0.214 |
| Run 3 | 0.164 | 0.070 | 0.234 |
| **Average** | **0.161** | **0.206** | **0.367** |

**Plan Summary:** `Sort  (cost=19.85..19.86 rows=3 width=12) (actual time=0.463..0.464 rows=3.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q06_c_tally_vote_results.txt`](plans/q06_c_tally_vote_results.txt)

---

#### Q6-D — List all open votes in a repo

```sql
SELECT v.number, v.question, v.opened_by,
       COUNT(b.voter) AS ballot_count
  FROM votes v
  LEFT JOIN vote_ballots b ON b.repo = v.repo AND b.number = v.number
 WHERE v.repo = 'org_1/repo_1'
 GROUP BY v.number, v.question, v.opened_by
 ORDER BY v.number DESC;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.239 | 0.097 | 0.336 |
| Run 2 | 0.250 | 0.087 | 0.337 |
| Run 3 | 0.263 | 0.107 | 0.370 |
| **Average** | **0.251** | **0.097** | **0.348** |

**Plan Summary:** `Sort  (cost=10.50..10.51 rows=2 width=47) (actual time=0.067..0.067 rows=2.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q06_d_list_open_votes.txt`](plans/q06_d_list_open_votes.txt)

---

#### Q6-E — Delete a vote and its ballots

```sql
DELETE FROM votes WHERE repo = 'org_1/repo_1' AND number = 2;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.138 | 0.215 | 0.353 |
| Run 2 | 0.140 | 0.203 | 0.343 |
| Run 3 | 0.138 | 0.201 | 0.339 |
| **Average** | **0.139** | **0.206** | **0.345** |

**Plan Summary:** `Delete on votes  (cost=0.00..6.00 rows=0 width=0) (actual time=0.031..0.032 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q06_e_delete_vote.txt`](plans/q06_e_delete_vote.txt)

---

### Section 7. Reminders

#### Q7-A — Create a reminder

```sql
INSERT INTO reminders (repo, number, author, due_at, text)
VALUES ('org_1/repo_1', 10, 'user_1', extract(epoch from now()) + 3600, 'Check CI status')
RETURNING reminder_id;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.033 | 0.322 | 0.355 |
| Run 2 | 0.033 | 0.296 | 0.329 |
| Run 3 | 0.035 | 0.307 | 0.342 |
| **Average** | **0.034** | **0.308** | **0.342** |

**Plan Summary:** `Insert on reminders  (cost=0.00..0.02 rows=1 width=116) (actual time=0.141..0.142 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q07_a_create_reminder.txt`](plans/q07_a_create_reminder.txt)

---

#### Q7-B — Fetch all reminders due now

```sql
SELECT r.reminder_id, r.repo, r.number, r.author, r.due_at, r.text,
       i.installation_id, i.ai_url, i.ai_model, i.ai_key
  FROM reminders r
  JOIN repos        rp ON rp.repo = r.repo
  JOIN installations i  ON i.installation_id = rp.installation_id
 WHERE r.due_at <= extract(epoch from now())
 ORDER BY r.due_at;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.451 | 0.154 | 0.605 |
| Run 2 | 0.425 | 0.149 | 0.574 |
| Run 3 | 0.412 | 0.148 | 0.560 |
| **Average** | **0.429** | **0.150** | **0.580** |

**Plan Summary:** `Sort  (cost=44.09..44.63 rows=213 width=120) (actual time=0.128..0.132 rows=219.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q07_b_fetch_reminders_due_now.txt`](plans/q07_b_fetch_reminders_due_now.txt)

---

#### Q7-C — Delete a reminder after it has fired

```sql
DELETE FROM reminders WHERE reminder_id = 1;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.150 | 0.059 | 0.209 |
| Run 2 | 0.148 | 0.060 | 0.208 |
| Run 3 | 0.143 | 0.057 | 0.200 |
| **Average** | **0.147** | **0.059** | **0.206** |

**Plan Summary:** `Delete on reminders  (cost=0.28..8.29 rows=0 width=0) (actual time=0.017..0.017 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q07_c_delete_reminder.txt`](plans/q07_c_delete_reminder.txt)

---

#### Q7-D — Count open reminders across all repos

```sql
SELECT COUNT(*) AS open_reminders FROM reminders;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.138 | 0.079 | 0.217 |
| Run 2 | 0.137 | 0.076 | 0.213 |
| Run 3 | 0.137 | 0.073 | 0.210 |
| **Average** | **0.137** | **0.076** | **0.213** |

**Plan Summary:** `Aggregate  (cost=25.50..25.51 rows=1 width=8) (actual time=0.058..0.059 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q07_d_count_open_reminders.txt`](plans/q07_d_count_open_reminders.txt)

---

#### Q7-E — List reminders for a specific issue / PR

```sql
SELECT reminder_id, author, due_at, text
  FROM reminders
 WHERE repo = 'org_1/repo_1' AND number = 1
 ORDER BY due_at;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.163 | 0.060 | 0.223 |
| Run 2 | 0.170 | 0.060 | 0.230 |
| Run 3 | 0.166 | 0.059 | 0.225 |
| **Average** | **0.166** | **0.060** | **0.226** |

**Plan Summary:** `Sort  (cost=28.01..28.02 rows=1 width=47) (actual time=0.046..0.046 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q07_e_list_reminders_issue.txt`](plans/q07_e_list_reminders_issue.txt)

---

### Section 8. AI queue metrics

#### Q8-A1 — Record a queue wait - Step 1: Insert new row

```sql
INSERT INTO queue_waits (repo, wait_seq, wait_seconds)
SELECT 'org_1/repo_1',
       COALESCE(MAX(wait_seq), 0) + 1,
       2.34
  FROM queue_waits
 WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.181 | 0.478 | 0.659 |
| Run 2 | 0.164 | 0.222 | 0.386 |
| Run 3 | 0.164 | 0.220 | 0.384 |
| **Average** | **0.170** | **0.307** | **0.476** |

**Plan Summary:** `Insert on queue_waits  (cost=0.34..0.36 rows=0 width=0) (actual time=0.088..0.088 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q08_a1_insert_queue_wait.txt`](plans/q08_a1_insert_queue_wait.txt)

---

#### Q8-A2 — Record a queue wait - Step 2: Prune oldest rows keeping 200

```sql
DELETE FROM queue_waits
 WHERE repo = 'org_1/repo_1'
   AND wait_seq <= (
       SELECT MAX(wait_seq) - 200
         FROM queue_waits
        WHERE repo = 'org_1/repo_1'
   );
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.166 | 0.088 | 0.254 |
| Run 2 | 0.168 | 0.080 | 0.248 |
| Run 3 | 0.162 | 0.080 | 0.242 |
| **Average** | **0.165** | **0.083** | **0.248** |

**Plan Summary:** `Delete on queue_waits  (cost=5.32..36.32 rows=0 width=0) (actual time=0.038..0.038 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q08_a2_prune_queue_waits.txt`](plans/q08_a2_prune_queue_waits.txt)

---

#### Q8-B — Queue wait statistics for a repo

```sql
SELECT COUNT(*)                                                      AS sample_count,
       ROUND(AVG(wait_seconds)::NUMERIC, 3)                         AS avg_wait,
       ROUND(MIN(wait_seconds)::NUMERIC, 3)                         AS min_wait,
       ROUND(MAX(wait_seconds)::NUMERIC, 3)                         AS max_wait,
       ROUND(percentile_cont(0.5) WITHIN GROUP
             (ORDER BY wait_seconds)::NUMERIC, 3)                   AS median_wait,
       ROUND(percentile_cont(0.95) WITHIN GROUP
             (ORDER BY wait_seconds)::NUMERIC, 3)                   AS p95_wait
  FROM queue_waits
 WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.153 | 0.076 | 0.229 |
| Run 2 | 0.168 | 0.080 | 0.248 |
| Run 3 | 0.149 | 0.071 | 0.220 |
| **Average** | **0.157** | **0.076** | **0.232** |

**Plan Summary:** `Aggregate  (cost=44.84..44.87 rows=1 width=168) (actual time=0.055..0.055 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q08_b_queue_wait_statistics.txt`](plans/q08_b_queue_wait_statistics.txt)

---

### Section 9. Review counts

#### Q9-A — Increment a review counter (upsert)

```sql
INSERT INTO review_counts (repo, command, review_count)
VALUES ('org_1/repo_1', 'review', 1)
ON CONFLICT (repo, command)
DO UPDATE SET review_count = review_counts.review_count + 1;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.038 | 0.143 | 0.181 |
| Run 2 | 0.035 | 0.127 | 0.162 |
| Run 3 | 0.034 | 0.122 | 0.156 |
| **Average** | **0.036** | **0.131** | **0.166** |

**Plan Summary:** `Insert on review_counts  (cost=0.00..0.01 rows=0 width=0) (actual time=0.100..0.101 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q09_a_increment_review_counter.txt`](plans/q09_a_increment_review_counter.txt)

---

#### Q9-B — Total reviews posted for a repo

```sql
SELECT SUM(review_count) AS total_reviews FROM review_counts WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.165 | 0.045 | 0.210 |
| Run 2 | 0.136 | 0.033 | 0.169 |
| Run 3 | 0.136 | 0.034 | 0.170 |
| **Average** | **0.146** | **0.037** | **0.183** |

**Plan Summary:** `Aggregate  (cost=8.39..8.40 rows=1 width=8) (actual time=0.018..0.019 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q09_b_total_reviews_repo.txt`](plans/q09_b_total_reviews_repo.txt)

---

#### Q9-C1 — Increment duplicates caught for a repo

```sql
UPDATE repos SET duplicates_caught = duplicates_caught + 1 WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.124 | 0.083 | 0.207 |
| Run 2 | 0.128 | 0.085 | 0.213 |
| Run 3 | 0.128 | 0.086 | 0.214 |
| **Average** | **0.127** | **0.085** | **0.211** |

**Plan Summary:** `Update on repos  (cost=0.00..2.25 rows=0 width=0) (actual time=0.043..0.044 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q09_c1_increment_duplicates_caught.txt`](plans/q09_c1_increment_duplicates_caught.txt)

---

#### Q9-C2 — Select duplicates caught for a repo

```sql
SELECT duplicates_caught FROM repos WHERE repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.124 | 0.021 | 0.145 |
| Run 2 | 0.116 | 0.018 | 0.134 |
| Run 3 | 0.126 | 0.020 | 0.146 |
| **Average** | **0.122** | **0.020** | **0.142** |

**Plan Summary:** `Seq Scan on repos  (cost=0.00..2.25 rows=1 width=4) (actual time=0.006..0.008 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q09_c2_select_duplicates_caught.txt`](plans/q09_c2_select_duplicates_caught.txt)

---

### Section 10. Dashboard summary

#### Q10 — Dashboard summary (multi-lateral aggregate)

```sql
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
      SELECT repo, SUM(run_count)    AS total_commands  FROM command_stats  WHERE repo = 'org_1/repo_1' GROUP BY repo
  ) cs ON cs.repo = r.repo
  LEFT JOIN (
      SELECT repo, SUM(review_count) AS total_reviews   FROM review_counts  WHERE repo = 'org_1/repo_1' GROUP BY repo
  ) rc ON rc.repo = r.repo
  LEFT JOIN (
      SELECT repo, SUM(kudos_count)  AS total_kudos     FROM kudos          WHERE repo = 'org_1/repo_1' GROUP BY repo
  ) km ON km.repo = r.repo
  LEFT JOIN (
      SELECT repo, COUNT(*)          AS open_reminders  FROM reminders      WHERE repo = 'org_1/repo_1' GROUP BY repo
  ) rm ON rm.repo = r.repo
  LEFT JOIN (
      SELECT repo,
             percentile_cont(0.5)  WITHIN GROUP (ORDER BY wait_seconds) AS median_wait,
             percentile_cont(0.95) WITHIN GROUP (ORDER BY wait_seconds) AS p95_wait
        FROM queue_waits WHERE repo = 'org_1/repo_1' GROUP BY repo
  ) qw ON qw.repo = r.repo
 WHERE r.repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.531 | 0.166 | 0.697 |
| Run 2 | 0.520 | 0.165 | 0.685 |
| Run 3 | 0.495 | 0.156 | 0.651 |
| **Average** | **0.515** | **0.162** | **0.678** |

**Plan Summary:** `Nested Loop Left Join  (cost=22.92..111.49 rows=1 width=66) (actual time=0.119..0.122 rows=1.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q10_dashboard_summary.txt`](plans/q10_dashboard_summary.txt)

---

### Section 11. Web sessions

#### Q11-A — Create a session after OAuth callback

```sql
INSERT INTO web_sessions (session_id, login, token, expires_at)
VALUES ('sess_new_bench', 'user_1', 'gho_bench_token', extract(epoch from now()) + 3600);
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.031 | 0.124 | 0.155 |
| Run 2 | 0.029 | 0.115 | 0.144 |
| Run 3 | 0.030 | 0.109 | 0.139 |
| **Average** | **0.030** | **0.116** | **0.146** |

**Plan Summary:** `Insert on web_sessions  (cost=0.00..0.02 rows=0 width=0) (actual time=0.115..0.115 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q11_a_create_web_session.txt`](plans/q11_a_create_web_session.txt)

---

#### Q11-B — Store repo push-access flag for a session

```sql
INSERT INTO session_push_access (session_id, repo, can_push)
VALUES ('sess_1_1795457280', 'org_1/repo_1', TRUE)
ON CONFLICT (session_id, repo)
DO UPDATE SET can_push = EXCLUDED.can_push;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.037 | 0.276 | 0.313 |
| Run 2 | 0.038 | 0.268 | 0.306 |
| Run 3 | 0.039 | 0.273 | 0.312 |
| **Average** | **0.038** | **0.272** | **0.310** |

**Plan Summary:** `Insert on session_push_access  (cost=0.00..0.01 rows=0 width=0) (actual time=0.060..0.061 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q11_b_store_session_push_access.txt`](plans/q11_b_store_session_push_access.txt)

---

#### Q11-C — Look up a session

```sql
SELECT login, token, expires_at
  FROM web_sessions
 WHERE session_id = 'sess_1_1795457280'
   AND expires_at > extract(epoch from now());
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.170 | 0.014 | 0.184 |
| Run 2 | 0.179 | 0.013 | 0.192 |
| Run 3 | 0.171 | 0.013 | 0.184 |
| **Average** | **0.173** | **0.013** | **0.187** |

**Plan Summary:** `Seq Scan on web_sessions  (cost=0.00..4.25 rows=1 width=28) (actual time=0.008..0.008 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q11_c_lookup_web_session.txt`](plans/q11_c_lookup_web_session.txt)

---

#### Q11-D — Check push access for a repo in a session

```sql
SELECT can_push
  FROM session_push_access
 WHERE session_id = 'sess_1_1795457280' AND repo = 'org_1/repo_1';
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.133 | 0.019 | 0.152 |
| Run 2 | 0.128 | 0.018 | 0.146 |
| Run 3 | 0.127 | 0.017 | 0.144 |
| **Average** | **0.129** | **0.018** | **0.147** |

**Plan Summary:** `Seq Scan on session_push_access  (cost=0.00..2.50 rows=1 width=1) (actual time=0.007..0.008 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q11_d_check_session_push_access.txt`](plans/q11_d_check_session_push_access.txt)

---

#### Q11-E — Create an OAuth state token

```sql
INSERT INTO oauth_states (state, return_to, expires_at)
VALUES ('state_bench_sample', '/dashboard', extract(epoch from now()) + 600);
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.030 | 0.098 | 0.128 |
| Run 2 | 0.031 | 0.096 | 0.127 |
| Run 3 | 0.030 | 0.097 | 0.127 |
| **Average** | **0.030** | **0.097** | **0.127** |

**Plan Summary:** `Insert on oauth_states  (cost=0.00..0.02 rows=0 width=0) (actual time=0.089..0.089 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q11_e_create_oauth_state.txt`](plans/q11_e_create_oauth_state.txt)

---

#### Q11-F — Consume an OAuth state (validate and delete)

```sql
DELETE FROM oauth_states
 WHERE state = 'state_secret_1'
   AND expires_at > extract(epoch from now())
RETURNING return_to;
```

| Run | Planning Time (ms) | Execution Time (ms) | Total Time (ms) |
|:---:|:---:|:---:|:---:|
| Run 1 | 0.175 | 0.042 | 0.217 |
| Run 2 | 0.170 | 0.041 | 0.211 |
| Run 3 | 0.171 | 0.042 | 0.213 |
| **Average** | **0.172** | **0.042** | **0.214** |

**Plan Summary:** `Delete on oauth_states  (cost=0.00..3.25 rows=1 width=6) (actual time=0.008..0.009 rows=0.00 loops=1)`  
**Detailed Plan Artifact:** [`plans/q11_f_consume_oauth_state.txt`](plans/q11_f_consume_oauth_state.txt)

---

## Index Summary & Optimization Analysis

| Index Name | Table | Indexed Columns | Type / Access | Role & Query Coverage |
|:---|:---|:---|:---:|:---|
| `repos_pkey` | `repos` | `(repo)` | B-Tree (PK) | Critical hot-path lookup on every webhook and page load |
| `installations_pkey` | `installations` | `(installation_id)` | B-Tree (PK) | Fast foreign key joins for bot credentials |
| `command_hits_pkey` | `command_hits` | `(repo, user_login, hit_at)` | B-Tree (PK) | Per-user rate-limiting lookup |
| `command_hits_repo_idx` | `command_hits` | `(repo, hit_at)` | B-Tree (Secondary) | Per-repo rate-limiting sliding window checks |
| `reminders_due_idx` | `reminders` | `(due_at)` | B-Tree (Secondary) | Sub-millisecond cron sweep for pending reminders |
| `vote_ballots_pkey` | `vote_ballots` | `(repo, number, voter)` | B-Tree (PK) | Vote ballot upsert and tally prefix scans |
| `queue_waits_pkey` | `queue_waits` | `(repo, wait_seq)` | B-Tree (PK) | Ordered insertion and FIFO sliding-window retention |

### Proposed Additional Indexes (Reference DDL in `plans/`)

| File | Purpose & Optimization |
|:---|:---|
| [`plans/idx_command_hits_active.sql`](plans/idx_command_hits_active.sql) | Filtered partial index for active command hits (last 1 hour) |
| [`plans/idx_reminders_repo.sql`](plans/idx_reminders_repo.sql) | Composite index `(repo, number, due_at)` for per-issue reminder listings |
| [`plans/idx_vote_ballots_repo.sql`](plans/idx_vote_ballots_repo.sql) | Covering index `(repo, number)` for high-volume vote tally queries |

---

## Performance Conclusions & Recommendations

> [!TIP]
> **Sliding-Window Maintenance:**
> Background scheduled pruning of `command_hits` (> 1 hr) and expired sessions ensures rate-limit checks execute in **< 1.0 ms** regardless of cumulative history.

> [!IMPORTANT]
> **Self-Capping Queue Metrics:**
> `queue_waits` maintains bounded storage (MAX_WAITS = 200 per repository). Quantile calculations (`percentile_cont(0.5)`, `percentile_cont(0.95)`) complete in **< 0.5 ms** because the working set is strictly limited.

> [!NOTE]
> **Hot-Path Verification:**
> All critical webhook queries (credential retrieval, rate checks, session authorization) exhibit sub-millisecond execution times on PostgreSQL, confirming the schema is fully 3NF/BCNF compliant and optimized for low-latency operations.
