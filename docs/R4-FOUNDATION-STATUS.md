# R4.0 foundation — initial implementation

This branch is intentionally observation-only for network configuration and process controls. It does not restore settings changed by earlier versions because no trustworthy prior snapshot exists; users must review macOS Network settings if an old version changed them. Do not deploy as a stable release.

Implemented changes: remove certificate bypass; use bundled CLI, versioned JSON, dynamic CLI discovery; disable legacy network mutation, forced process termination and automatic speed probing; mark blocklist state unknown pending validated parser; bundle resources and user-local install target; add core accounting prototype, tests and draft contracts. Second iteration integrates scoped multi-interface observation into the legacy App, adds typed draft contracts and informational quota evaluator, separates unclassified bytes and sample gaps, and displays them in the UI.

Open gates:  provider reconciliation/staleness and policy unit verification incomplete; native UI and SQLite/history migration pending; manual speed probe still uses legacy fixed interface selection; per-process attribution and workflow protection not validated; pure recovery state machine implemented; durable host journal, authorization and real adapter not implemented; launch-at-login migration and complete subprocess lifecycle hardening pending; macOS compilation, CI and hardware evidence required. No paid services or signing/notarization are part of this branch.

Keep main unchanged until independently verified. No release readiness claim.

## Second iteration limitations

Scope attribution is estimated, based on interface type, addresses and an explicit active-interface override; private addresses alone do not establish campus membership. Interface counters include local traffic, can wrap, and are not campus billing counters. Long sampling gaps and day changes discard unresolvable deltas and record uncertainty. The first sample after startup/wake establishes a fresh baseline; history and provider reconciliation still need migration and real-device verification. Typed contract models and scoped accounting are implemented but not frozen; transactional routing and authorization remain disabled.

## Third iteration

- Added a pure recovery state machine with prepared/applied/committed/rolled-back effects, journal-before-write, compare-and-swap preconditions, ambiguous write handling and crash recovery.
- Added seven recovery tests; these are simulated effects, not macOS network mutations.
- Added strict daily-state migration decoder and three tests, integrated into the legacy app. Invalid or future-dated data blocks writes and is preserved; previous-day raw state is archived first. UI exposes persistence errors.
- Contract review, public API initialization/validation, durable journal, ownership semantics and real-device checks are not complete. Full parallel unlock remains blocked. No paid services or external release.

## Fourth iteration

- Added validated atomic JSON recovery journal and simulated compare-and-swap adapter, with five new tests. Single local writer only; fsync durability and multi-process locking are not established. No real network adapter is enabled.
- Recovery rejects malformed journal entries before interpreting their state.
- Applied simple-first UX in the legacy WebView: compact adaptive popover, primary information first, collapsed advanced section, keyboard focus styles, reduced motion, placeholder/unknown status, hidden unavailable quick actions. No claim of native SwiftUI completion or UX acceptance testing.
- Contract freeze, full version validation of other shared models, provider policy verification, and real-device recovery remain open. CI evidence must correspond to exact HEAD.

## Fifth iteration

- Campus ranking now parses one row at a time, rejects duplicate or malformed matches, validates HTTPS response destination and limits response size. Displayed provider units remain unverified; never merge ranking numbers into local byte totals. Retrieval date/time, request identity, in-flight guard and freshness are tracked. Live campus format and accounting policies still require on-campus verification; the parser fixtures are synthetic.
- Added structural v1 validation and validated decode for all eight shared contract types; authorization, cryptographic verification and version compatibility remain separate concerns. Three contract tests and five provider/parser tests added.
- Added proposed role/path ownership and parallel unlock checklist. Contract freeze and full parallel development remain blocked pending integrated CI and review. No paid services.

## Sixth iteration

- Added system SQLite daily history store (schema v1, atomic transaction import, prepared statements, bounded recent query, unknown directional values preserved). The original legacy JSON remains untouched; import never replaces an existing SQLite day. App history uses cached SQLite rows, with one diagnostic status instead of additional controls. Legacy CLI still reads the old history file; CLI migration remains open.
- Added read-only prioritized diagnostic engine and six tests (four storage, two diagnostics). Missing historic days and unknown direction values are identified; chart averages use recorded days. Detailed time-series/scoped history, CSV export, retention, migration of previously fabricated legacy ratios and data recovery remain open. Local history and provider limits are distinct.
- SQLite links against macOS system library without a paid dependency. Latest app/SQLite build and all tests must pass at the exact integrated HEAD before merge. No real network changes or paid services.

## Seventh iteration

- Added local conditional rate forecasting: rolling 180-sample maximum, minimum 30 continuous seconds and 30 samples, interquartile rate scenarios, independent download/upload/total budgets, no forecast for unstable/idle or long-horizon rates. Same-scope data, identity changes, gaps and incomplete daily accounting gate the forecast. It is not a calibrated confidence interval or a provider-verified limit.
- Local estimated quota policy evaluates 70/85/95% tiers and tracks one notification attempt per increasing tier, scope and day within the running process. Ledger is not persisted yet; notification delivery and permissions require real-device validation. Existing AppleScript notification program now receives arguments as data, not interpolated script code. No automatic network or process action.
- Replaced instantaneous-speed ETA with conditional range/status in the compact UI; accounting day aligned to Asia/Taipei (historical chart timezone consistency and official provider reset remain unverified). Five new unit tests. All changes require exact-HEAD CI validation. No paid services.

## Eighth iteration

- Added explicit session-only important-work mode (one-click toggle): pauses new optional provider, ping, process-traffic and speed probes while retaining interface sampling and quota reminders. Already-running subprocesses are not forcibly terminated. No claim of automatic Codex recognition, application-level bandwidth reservation or protection against external network changes.
- Separate display sleep from actual system sleep. System sleep invalidates baselines and provider/prediction state; wake refreshes discovery and restarts sampling without inventing sleeping-period deltas. Ping results are generation/identity checked; ICMP failures no longer imply link loss. Three state-machine tests added. Legacy subprocess paths and actual sleep/wake behavior still require validation.
- No paid services or host configuration mutation. Exact integrated CI and real-device checks remain mandatory.
