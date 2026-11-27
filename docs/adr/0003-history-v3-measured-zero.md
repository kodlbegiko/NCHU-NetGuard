# ADR — History SQLite v3 measured zero

Status: candidate, exact CI required.

The v2 scope CHECK rejected zero rows even when measured intervals existed. v3 permits known-scope zero rows; a missing row remains unknown. The v2 table is rebuilt within the existing migration transaction, with no synthetic rows or reclassification. Existing v1 aggregate-only records remain aggregate-only. Unknown-scope zero remains invalid. Backup preflight supports v1/v2/v3 and CLI accepts all three. Old writers reject v3; downgrade requires an independently reviewed export/migration, never editing user_version. These rows establish partial observed bytes, not a complete billing day.
