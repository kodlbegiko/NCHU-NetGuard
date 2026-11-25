# Master engineering tracker

Scope: full R4–R6 roadmap and the uploaded engineering plan. Status is evidence-based, not a completion percentage. This index supersedes the old tracker as the phase-level entry point; [R4 P0/P1 tracker](R4-P0-P1-MASTER-TRACKER.md) retains detailed historical findings and commits. No row is Done merely because a model or fixture exists.

Baseline verified candidate: 07ca43ef09e1fd4fa661c1df5d0cf4a5eeb83140, [CI 45656403277](https://github.com/kodlbegiko/NCHU-NetGuard/actions/runs/45656403277), 206 Swift tests and 31 Python tests passed; both bundles and four-view fixture smoke passed. Host parser and UDP evidence inconclusive. Main unchanged. Actual user Mac not accessible; container is Linux and direct GitHub git transport DNS failed.

| Task | Phase / owner | Priority | Remaining acceptance | Evidence / status |
|---|---|---|---|---|
| R4-TRAFFIC | 1 / 1 | P0 | Actual independent route evidence, VPN dedup, dual stack and UDP compatibility, same-boundary <=1% error | In Progress; partition projection 140823d7, no live attribution |
| R4-PROVIDER | 1 / 7 | P0 | Billing units/reset/identity, authoritative reconciliation, detailed error classification | In Progress; monotonic refresh gate 17e80468; official/device evidence still required |
| R4-SECURITY | 1 / 3 | P0 | Complete trust-boundary review, identity/lifecycle/race tests, negative TLS cases | In Progress; baseline CI is not full security audit |
| R4-RECOVERY | 1 / 3 | P0 | Exhaustive fault injection and authorization, real adapter and device rollback | In Progress; exact rollback evidence e05ea4c4; live mutation disabled |
| R4-CONTRACT | 2 / 0 | P1 | Complete consumer inventory, semantic review and owner approval | In Progress; 47 production Swift files scanned; lexical inventory and drift test added; runtime consumption, external review and approval open |
| R4-ARCH | 2 / 0 | P1 | Modular default, smaller runtime, boundaries and exact integration review | In Progress; both build variants passed baseline |
| R4-PARALLEL | 2 / 0,8 | P1 | All unlock gates and owner approval | Not Started for formal unlock |
| R4-APPS | 3 / 2,6 | P1 | Stable identity, coverage and route-aware attribution | In Progress; existing heuristic observations only |
| R4-WORKFLOW | 3 / 6 | P1 | Task/session lifecycle, trustworthy opt-in identity, device validation | In Progress |
| R4-POLICY | 3 / 5 | P1 | Runtime rule editor, persistence, cooldown, evidence/calibration | In Progress; read-only rules preview 70f10e4c |
| R4-DATA | 3 / 7 | P1 | Unified history, bounded migration, atomic multi-store restore, failure tests | In Progress |
| R4-UX | 3 / 4 | P1 | Native parity, accessibility, novice and device tests | In Progress |
| R4-COMPETITIVE | 4 / 0,1,2,6,7 | P1 | Independent implementation and verified feature matrix | In Progress; see competitive benchmark; no third-party code import |
| R5-QA | 5,7 / 8 | P1 | Exact current CI, coverage >=90%, real device metrics and 168h soak | In Progress; actual hardware and duration evidence missing |
| R5-LIFECYCLE | 5 / 0,8 | P2 | Upgrade/rollback, install/uninstall, compatibility, RC | In Progress; no release |
| R6-PROVIDERS | 6 / 7 | P2 | Universal SDK, registry and independent fixtures | Not Started |
| R6-PLUGIN | 6 / 0,3 | P2 | Capability isolation, permission model and validation | Not Started |
| R6-API-MCP | 6 / 0,7 | P2 | Native CLI, read-only local API/MCP and protocol tests | Not Started |
| R6-EXTENSION | 6 / 2,3 | P2 | Public API feasibility, entitlement, mock and authorized device tests | In Progress for design; activation not authorized |

Acceptance targets and dependencies follow ROADMAP.md, UX-PRINCIPLES.md, AGENTS.md and the full engineering plan. The rows are work packages, not atomic closure counts. Split them into findings with tests and SHA when work advances. Independent CI and device evidence must remain distinct. No P0/P1 close or parallel unlock implied.

- R4-TRAFFIC: local day rollback holds the accepted ledger and disables estimates/alerts; finalized history is insert-if-absent. Persist affirmative per-scope measured interval evidence so absence is not zero. Main status, quick panel, personal budget, quota assessment and WebView estimate availability consume the guard. Alert dispatch now requires successful reservation write. Legacy history/advanced chart completeness and real-device clock/coverage validation remain open. Added pure module regression tests; exact CI pending.

- R4-DATA/SECURITY: serialize schema inspection and migration in one SQLite write transaction; enforce trusted_schema OFF and NOFOLLOW, reject unsupported table inventory/column shape and triggers before migration, bound backup inspector VM work. Tests cover unrelated schema preservation, symlink rejection and concurrent initialization. This is not full multi-store restore or a defense against every non-cooperating filesystem race; exact CI pending.

- R4-UX/TRAFFIC: legacy history and chart no longer classify aggregate historical totals against the active network quota. Unknown days remain absent, height is relative to observed bytes, old chart rows clear, and local estimate availability is scope-gated. Actual UI interaction and accessibility remain unverified.
