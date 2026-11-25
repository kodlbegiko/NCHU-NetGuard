# ADR 0002 — Exact rollback evidence in journal v1

Status: implemented candidate, independent CI pending.

The existing rolledBack state recorded the applied revision, but recovery accepted any later revision with the original settings. An unrelated edit could therefore look like confirmed rollback. Add optional `restored` configuration to the internal journal v1. It must match the previously owned settings, have a later revision than `applied`, and appear only in rolledBack phase. New writes require it. Legacy journals can be decoded without the field but cannot establish verified rollback; they enter safe mode. This is a backward-readable additive change, not permission to mutate a host. The simulated adapter revision model still requires separate real-world verification before any live adapter.
