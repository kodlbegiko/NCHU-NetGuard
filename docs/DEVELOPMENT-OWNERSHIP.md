# R4 parallel-development ownership

Status: proposed allocation; broad parallel implementation remains locked. No real user/team CODEOWNERS are invented. Agent numbers are roles, not GitHub identities.

| Role | Owned paths (current transitional layout) |
|---|---|
| 0 Architect/integrator | Package.swift, Contracts.swift, ContractValidation.swift, QuickPanelState.swift, ManagementSnapshot.swift, AutomationSnapshot.swift, docs/contracts/, docs/adr/, integration approvals |
| 1 Traffic | TrafficAccounting.swift, ScopedAccounting.swift |
| 2 Network | Diagnostics.swift, NetworkQuality.swift, AppTrafficSample.swift, future NetworkEngine/ and PlatformAdapters/ read-only network discovery |
| 3 Security/recovery | ProbeRunner.swift, RecoveryTransaction.swift, RecoveryJournalStore.swift, SimulatedNetworkAdapter.swift, future authorization layer |
| 4 UX | src/QuickPanel.swift, src/HistoryAnalyticsView.swift, src/SettingsView.swift, src/ManagementView.swift, src/AutomationView.swift, src/Resources/popover.html, future Apps/NetGuardApp/; UX-01–08 |
| 5 Policy/forecast | PolicyEngine.swift, PredictionEngine.swift, future policy/forecast modules |
| 6 Workflows/power | WorkflowPowerGuard.swift, future workflow/power adapters |
| 7 Data/provider | HistoryStore.swift, HistoryBackupInspector.swift, HistoryAnalytics.swift, HistoryChartProjection.swift, UsageMigration.swift, ProviderObservation.swift, scripts/traffic_monitor.py, future DataStore/ and CampusProviders/ |
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

## Machine-checkable boundary

`docs/module-ownership.json` assigns every current core Swift source exactly one role. `tests/test_module_boundaries.py` verifies manifest coverage, the absence of UI framework imports in core, and a single core Process launcher. These are architectural static guardrails, not a security sandbox, GitHub CODEOWNERS enforcement, or a complete package dependency audit. Shared legacy runtime/build/contract changes still require integrator review. Future file additions must update the manifest and this allocation together.

## First compiled module split

SwiftPM now declares NetGuardObservation (NetworkQuality and AppTrafficSample) and NetGuardWorkflow (WorkflowPowerGuard) as independent library targets without dependencies on NetGuardCore or each other. NetGuardCore depends on both and preserves the old public type names via explicit type aliases. New test targets import only their corresponding module. The manifest and static guards cover all Sources directories and allowed imports. The app Makefile still flattens Swift source files into the legacy executable, rather than linking the SwiftPM module products; conversion to an executable target remains outstanding. Shared contracts, data and recovery stay in NetGuardCore pending deeper dependency analysis. Exact-HEAD CI and integrator approval remain required before any new parallel unlock.
