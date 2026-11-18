# Tidebot ER Diagram

This document describes the Entity-Relationship diagram for Tidebot's relational schema derived during normalization. The Mermaid diagram below covers all persistent tables (memory-only tables are shown with a note).

## ER Diagram

```mermaid
erDiagram
    INSTALLATIONS {
        int     installation_id PK
        text    ai_url
        text    ai_model
        text    ai_key
    }

    REPOS {
        text    repo PK
        int     installation_id FK
        int     duplicates_caught
    }

    REPO_CONFIG {
        text    repo PK, FK
        bool    auto_label
        bool    size_labels
        bool    star_gate
        bool    triage_label
        bool    pr_lint
        bool    duplicate_check
    }

    REVIEWER_RULES {
        text    repo FK
        int     position
        text    pattern
    }

    REVIEWER_RULE_OWNERS {
        text    repo FK
        int     position FK
        text    owner
    }

    COMMAND_STATS {
        text    repo FK
        text    command
        int     run_count
    }

    KUDOS {
        text    repo FK
        text    login
        int     kudos_count
    }

    VOTES {
        text    repo FK
        int     number
        text    question
        text    opened_by
    }

    VOTE_BALLOTS {
        text    repo FK
        int     number FK
        text    voter
        text    choice
    }

    REMINDERS {
        int     reminder_id PK
        text    repo FK
        int     number
        text    author
        float   due_at
        text    text
    }

    COMMAND_HITS {
        text    repo FK
        text    user_login
        float   hit_at
    }

    QUEUE_WAITS {
        text    repo FK
        int     wait_seq
        float   wait_seconds
    }

    REVIEW_COUNTS {
        text    repo FK
        text    command
        int     review_count
    }

    %% Memory-only tables (lost on restart)
    WEB_SESSIONS {
        text    session_id PK
        text    login
        text    token
        float   expires_at
    }

    SESSION_PUSH_ACCESS {
        text    session_id FK
        text    repo
        bool    can_push
    }

    OAUTH_STATES {
        text    state PK
        text    return_to
        float   expires_at
    }

    %% Relationships
    INSTALLATIONS ||--o{ REPOS : "hosts"
    REPOS ||--|| REPO_CONFIG : "has config"
    REPOS ||--o{ REVIEWER_RULES : "has rules"
    REVIEWER_RULES ||--o{ REVIEWER_RULE_OWNERS : "has owners"
    REPOS ||--o{ COMMAND_STATS : "tracks"
    REPOS ||--o{ KUDOS : "tracks"
    REPOS ||--o{ VOTES : "has"
    VOTES ||--o{ VOTE_BALLOTS : "receives"
    REPOS ||--o{ REMINDERS : "has"
    REPOS ||--o{ COMMAND_HITS : "logs"
    REPOS ||--o{ QUEUE_WAITS : "records"
    REPOS ||--o{ REVIEW_COUNTS : "counts"
    WEB_SESSIONS ||--o{ SESSION_PUSH_ACCESS : "grants"
```

## Cardinalities explained

| Relationship | Type | Reason |
|---|---|---|
| `installations` → `repos` | 1 : N | One App installation can serve many repos |
| `repos` → `repo_config` | 1 : 1 | Every repo has exactly one `.tide.yml` config |
| `repos` → `reviewer_rules` | 1 : N | A repo can have many CODEOWNERS-style rules |
| `reviewer_rules` → `reviewer_rule_owners` | 1 : N | One glob pattern can map to many owners/teams |
| `repos` → `votes` | 1 : N | A repo can have votes on many issues (at most one open vote per issue number) |
| `votes` → `vote_ballots` | 1 : N | One vote gets one ballot per voter; voters may change their answer |
| `web_sessions` → `session_push_access` | 1 : N | One session stores push-access flags for all repos the user visited |

## Notes

- **`ai_key`** is nullable — installations that use a public endpoint don't need a key.
- **`installation_id`** in `repos` is nullable — a repo may be known before its installation webhook fires.
- **Memory-only tables** (`web_sessions`, `session_push_access`, `oauth_states`) are recreated empty on every restart; they appear in the ER diagram for completeness but are not persisted.
- **`reviewer_rules.position`** exists because CODEOWNERS semantics require order: the last matching rule wins.
- **`queue_waits`** keeps at most 200 rows per repo (`MAX_WAITS` in `metrics.py`) to bound state-file growth.
