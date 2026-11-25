# R4 parallel-development ownership

Status: proposed allocation; broad parallel implementation remains locked. No real user/team CODEOWNERS are invented. Agent numbers are roles, not GitHub identities.

| Role | Owned paths (current transitional layout) |
|---|---|
| 0 Architect/integrator | Package.swift, Contracts.swift, ContractValidation.swift, docs/contracts/, docs/adr/, integration approvals |
| 1 Traffic | TrafficAccounting.swift, ScopedAccounting.swift |
| 2 Network | Diagnostics.swift, future NetworkEngine/ and PlatformAdapters/ read-only network discovery |
| 3 Security/recovery | RecoveryTransaction.swift, RecoveryJournalStore.swift, SimulatedNetworkAdapter.swift, future authorization layer |
| 4 UX | src/Resources/popover.html, future Apps/NetGuardApp/; UX-01–08 |
| 5 Policy/forecast | PolicyEngine.swift, PredictionEngine.swift, future policy/forecast modules |
| 6 Workflows/power | future WorkflowGuard/ and PowerGuard/ |
| 7 Data/provider | HistoryStore.swift, UsageMigration.swift, ProviderObservation.swift, scripts/traffic_monitor.py, future DataStore/ and CampusProviders/ |
| 8 QA/CI | Tests/, tests/, .github/workflows/, evidence and integration checks |

Shared legacy src/main.swift and Makefile: Agent 0 serializes modifications. Agents propose narrowly scoped patches to Agent 0, not concurrent edits. Test changes accompany their owned module and require QA review. Every branch states scope and base SHA, contract version, test results, migration/rollback impact and unresolved issues.

Unlock checklist:
- [ ] Exact latest integrated HEAD compiles and all registered CI tests pass.
- [ ] Eight contracts have validated decode paths, representative golden fixtures, reviewed invariants and explicit version evolution rules.
- [ ] No overlapping edits to shared runtime, contract or build files without integration approval.
- [ ] Independent module/adapter tests run without touching real network settings.
- [ ] Open P0/P1 hazards are fixed or explicitly disabled with visible UX and blockers documented.
- [ ] Integration owner confirms ownership, dependencies, review/merge policy and unlock scope.

Do not confuse a documentation checklist with completion. No paid runners, cloud services, publication, signing or notarization. Read UX-PRINCIPLES.md before user-facing changes.
