# R4.0 foundation — initial implementation

This branch is intentionally observation-only for network configuration and process controls. It does not restore settings changed by earlier versions because no trustworthy prior snapshot exists; users must review macOS Network settings if an old version changed them. Do not deploy as a stable release.

Implemented changes: remove certificate bypass; use bundled CLI, versioned JSON, dynamic CLI discovery; disable legacy network mutation, forced process termination and automatic speed probing; mark blocklist state unknown pending validated parser; bundle resources and user-local install target; add core accounting prototype, tests and draft contracts. Second iteration integrates scoped multi-interface observation into the legacy App, adds typed draft contracts and informational quota evaluator, separates unclassified bytes and sample gaps, and displays them in the UI.

Open gates:  provider reconciliation/staleness and policy unit verification incomplete; native UI and migration pending; manual speed probe still uses legacy fixed interface selection; per-process attribution and workflow protection not validated; transactional authorized mutation/recovery not implemented; launch-at-login migration and complete subprocess lifecycle hardening pending; macOS compilation, CI and hardware evidence required. No paid services or signing/notarization are part of this branch.

Keep main unchanged until independently verified. No release readiness claim.

## Second iteration limitations

Scope attribution is estimated, based on interface type, addresses and an explicit active-interface override; private addresses alone do not establish campus membership. Interface counters include local traffic, can wrap, and are not campus billing counters. Long sampling gaps and day changes discard unresolvable deltas and record uncertainty. The first sample after startup/wake establishes a fresh baseline; history and provider reconciliation still need migration and real-device verification. Typed contract models and scoped accounting are implemented but not frozen; transactional routing and authorization remain disabled.
