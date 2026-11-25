# R4 P0/P1 master tracker — closure candidate
Baseline: 49b28d60fe1056c14afb5f75e6d2d3cb19d2b1fe; candidate CI [45649994495](https://github.com/kodlbegiko/NCHU-NetGuard/actions/runs/45649994495) success. Hosted parser/flow checks are non-gating and not device evidence. Foundation ref 335c5be8 was not advanced (API error, ref re-read confirmed). Main unchanged. Local working tree not accessible to this agent.

Status vocabulary: Not Started / In Progress / Implemented / Tested / CI Verified / Device Verified / Blocked. A row is not closed until its own acceptance evidence is present. This is an initial inventory, not a full source audit; split rows into atomic findings as work proceeds.

| ID | Priority | Module / root concern | Acceptance / dependencies | Status and evidence |
|---|---|---|---|---|
| NG-001 | P0 | Security: legacy TLS bypass | Standard trust; negative certificate fixtures; no fallback | Implemented baseline; security audit open |
| NG-002 | P0 | Traffic: scope, counter gaps, interface/VPN double count | Directional independent baselines; discontinuity/IPv6/UDP/VPN fixture and host evidence; unknown scope explicit | In Progress; experimental flow is not billing |
| NG-003 | P0 | Network: command outcome and timeout | Fixed argv, bounded subprocess output and lifecycle; verified outcomes | In Progress; real mutation disabled |
| NG-004 | P0 | Recovery: snapshot, transaction, crash durability | Simulated failure injection, durable journal, authorization, separately authorized device rollback | In Progress; real adapter disabled |
| NG-005 | P0 | Security/workflow: unsafe process control | No unauthorized process controls; identity and consent gates | Implemented safe mode; full review open |
| NG-006 | P1 | Runtime: hardcoded paths/interfaces | Portable build/run, dynamic discovery and hardware tests | In Progress |
| NG-007 | P1 | CLI JSON and history parity | Versioned validated JSON, SQLite parity, regression checks | In Progress |
| NG-008 | P1 | Provider: fragile ranking and stale data | Official policy, fixtures, identity, error/freshness, on-campus reconciliation | In Progress; policy and device evidence outstanding |
| NG-009 | P1 | Network: unreliable service classification | Verified IPv4/IPv6/DNS/VPN attribution or explicit unknown | In Progress |
| NG-010 | P1 | Runtime/UI: flattened compilation and bridge trust | True module linkage, contract guards, native UI parity, accessibility and security tests | In Progress |
| NG-012 | P1 | Accounting units and day/reset | Verified provider units and reset; separate estimates | In Progress |
| R4-P0-JOURNAL-READ | P0 | Recovery: whole-file load before byte limit | Bounded read before decode; oversized journal rejected and preserved | Implemented in closure candidate; added regression test, CI pending |
| R4-P0-PROVIDER | P0 | Provider billing reconciliation | Official policy and on-campus observations; unknown if unavailable | In Progress; external evidence required |
| R4-P0-AUTH | P0 | Recovery: real authorization and network mutation | Explicit consent, device rollback evidence; no live mutation in CI | Blocked for device execution; engineering review remains |
| R4-P1-CONTRACT | P1 | Contracts: freeze and compatibility | Registry, golden fixtures, drift gate, owner approval | In Progress |
| R4-P1-MODULE | P1 | Architecture: parallel unlock | Exact HEAD CI, independent modules, integrator approval | In Progress |
| R4-P1-DATA | P1 | Data: retention, concurrency, migrations and backup | Fault injection, cross-process exclusion, integrity and V1/V2 tests | In Progress |
| R4-P1-WORKFLOW | P1 | Observation: AI attribution, sleep/idle | Identity, coverage, lifecycle and real host tests | In Progress |
| R4-P1-POLICY | P1 | Forecast/policy | Validated profiles, stale/gap handling, regression tests | In Progress |
| R4-P1-UX | P1 | Native UI/accessibility | UX gates, normal startup and human interaction evidence | In Progress |
| R4-P1-PERF | P1 | Performance | Reproducible actual M4 benchmark, budgets, long-running tests | Blocked for physical-device measurements |
| R4-P1-QA | P1 | QA/integration | Exact closure HEAD local and independent CI, regression review | In Progress |

Next: review exact branch CI, audit all trust boundaries, verify recovery journal durability/locking and lifecycle, provider policy, module migration and contracts. No main merge, paid services, real network mutation, or freeze approval implied.

## Closure batch 2 (candidate, not CI verified)
- P0 ranking ambiguity: reject duplicate identity rows even when one is malformed; regression added.
- P0/P1 CLI honesty: missing/invalid local state and campus-only identity are not reliable dorm measurements; return unknown while retaining separate provider payload; regression added. Legacy CLI dorm quota output is intentionally suppressed pending verified scope; this is a conservative behavior change, not complete CLI parity.
- P1 provider freshness: reject non-finite or negative age window; regression added.
- P1 history: bounded read and validated row decoder prevent oversized reads and direct decoding of overflowing values; two regressions added.
- P1 contract: golden fixtures now compare emitted field sets and semantic JSON values, not just decode round trips. Registry/freeze and owner approval remain open.
- Official NCHU evidence recorded separately; live policy and billing reconciliation remain open.

## Closure batch 3 (candidate)
- Remove false midnight quota-ready notification and misleading mode labels; no new real host mutations.
- Explicit CLI local bucket selection restores safe access to campus/dorm observed totals; no provider remaining bytes without verified units. Existing Swift caller still receives ranking JSON independently. New regression.
- Bound reads in connection/event/bundle archive; validate decoded connection session directly; add overflow and oversized regression cases.
- Reject non-regular recovery journal path, including symlinks, before read. This is not race-free O_NOFOLLOW, nor cross-process locking/durability; those gates remain open.
- Existing Foundation CI extended to allow pushes on closure candidate branches, all gating steps unchanged. PR creation and non-forced ref update remain blocked by connector errors. No exact-HEAD result yet.

## Closure batch 4 (candidate)
- Machine-readable v1 contract registry for eight models, semantic boundaries and required/optional field sets; automated fixture/registry/validator agreement check. Consumer review and owner approval pending.
- Module graph guard now verifies literal SwiftPM target dependency lists against ownership manifest and checks for dependency cycles. Actual native target migration remains open.

## Closure batch 5 (candidate)
- Replace disk-spooled ProbeRunner with nonblocking pipe and strict in-memory output ceiling; no shell; bounded polling and timeout. Isolated Linux Swift harness passed eight cases (success, failure, timeout, overflow, exact limit, infinite producer, invalid UTF-8, allowed exit). macOS exact candidate CI pending; noncooperative child/descendant termination remains explicitly not guaranteed.
- Remove unused legacy direct Process launchers, hardcoded wired gateway fallback, and unused media key injection path; retained active observation/notification code. Static guard prohibits direct app Process launchers. No network mutations or process-tree termination enabled.

## Closure batch 6 (candidate)
- Introduce true SwiftPM NetGuardApp executable target and separate packaged module-linkage build/smoke. Add CI gate without removing legacy build/smoke. ProbeRunner package-scoped; no public subprocess API. Exact compilation required before changing default build or claiming migration complete.

## Closure batch 7 (candidate)
- Recovery journal descriptor-relative no-follow open, regular/single-link/owner validation, nonblocking advisory lock spanning read-check-write, unique private temp file, file fsync and directory fsync after atomic rename. Ambiguous post-write failure explicitly distinct. Isolated Linux POSIX primitives check passed; macOS exact candidate CI required. Hardware durability and noncooperating writer protection not claimed.
- Recovery plan bounds; immutable applied evidence across phase transition; explicit persisted/notWritten/unknown outcome, safe mode for ambiguous writes, terminal crash recovery checks current observed revision/settings. Four regression cases. Real adapter still disabled.

## Closure batch 8 (candidate)
- Add checked UInt64 daily ledger and migrate validation through aggregate ceiling and bounded document size. Three regression cases. Production runtime integration still pending; physical/provider measurement boundaries unchanged.
