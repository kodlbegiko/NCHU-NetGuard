# V1 semantic review — observation and planning scope

Status: engineering review completed for this candidate; not approval by the owner or evidence of runtime integration. The wire candidate is intentionally restricted to observation, informational policy and inert planning. The aspirational fields in ROADMAP are not present in all v1 models.

| Contract | Permitted interpretation | Explicitly missing / prohibited |
|---|---|---|
| TrafficSnapshot | Raw per-interface counters at a timestamp; sample quality describes observation | Not billing, not daily completeness, not reliable traffic attribution by itself |
| NetworkSnapshot | Interface/service labels, scope estimate and quality | No authoritative route table, IP family, connectivity or stable platform identity guarantees |
| QuotaProfile | Declared byte limits and reset time zone; policyVerified is a provenance assertion | No proof of official policy; caller cannot set true merely because decode succeeds |
| PolicyDecision | Informational recommendation with expiry; no mutation capability | No input snapshot IDs, priority, authorized execution or dry-run proof |
| NetworkAction | Inert plan with target, precondition token and bounded timeout | No actual authority, verified postconditions, approval token or safe platform adapter |
| RecoverySnapshot | Descriptive owned settings and integrity token | Token is not a verified digest; no durable write or ownership proof |
| ProtectedWorkflow | Explicit opt-in record with expiry, opaque process label | No process authentication, OS protection or bandwidth reservation |
| EventRecord | Local redacted event metadata | No guarantee that free-text strings are redacted; producer must enforce privacy |

## Invariants and trust

- Structural validation bounds document size to 1 MiB, string fields to 4096 UTF-8 bytes, interface arrays and owned configuration to 256 entries. Dates must be finite; measured traffic snapshots cannot have an empty interface set.
- Current-time checks are separate from historical decoding. Expired decisions are not current, and expired or non-opted-in workflows do not express current preference.
- Existing wire field names remain unchanged. Added validation is a candidate tightening before freeze; no previously released v1 compatibility is assumed. It does not authenticate external inputs.
- NetworkAction and RecoverySnapshot remain data only. All real mutation requires a separately reviewed execution contract, actual authorization, verified pre/postconditions, durable journal and tested recovery.
- Never import user identifiers into fixtures, publish raw addresses, or infer safe status from missing data.

## Review outcome

Observation-only interfaces may be proposed for a scoped v1 freeze once exact integrated CI succeeds and the integration owner approves. Mutation-related contracts and actual platform execution remain explicitly excluded. Later contracts requiring omitted fields need versioned extensions/new versions plus ADR and tests. Do not mark broad parallel development unlocked. Isolated test, documentation and non-overlapping read-only module work remains permitted under ownership controls.

- Expanded v1 golden-fixture verification requires every top-level required key and every nested interface key independently; absence must fail validated decoding. Optional EventRecord fields remain absent in its required-only fixture. No wire field, version or semantics changed. This is compatibility test strengthening, not owner freeze approval or end-to-end integration proof.
