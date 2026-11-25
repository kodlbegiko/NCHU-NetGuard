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

## Ninth iteration

- Added ProbeRunner for read-only commands, with deadline, output-size monitoring, fixed argv, isolated temporary output and exit-status checks. Migrated default IPv4 discovery, ping, nettop and provider CLI. The deadline is best-effort; a non-cooperative own child or descendant may survive termination, and output growth between polls is not strictly capped. Remaining legacy subprocess paths need audit.
- Added rolling latency-quality state (minimum three samples, five-sample window, stale after 120 seconds), app-process snapshot parsing and four unit tests. Removed old fixed-interface speed race, fabricated speed estimates and misleading comparisons. App data is a process snapshot, not authoritative per-interface or daily attribution. App names are inserted using textContent; no claim that the full WebView is injection-proof.
- Default route/address discovery is off the main thread and generation checked. IPv6-only/VPN-specific discovery and host reachability remain unverified; default IPv4 address is not internet reachability.
- Latest integrated build required. CI had passed earlier core tests but the earlier app build was superseded. No paid service, real network mutation or release.

## Tenth iteration

- Complete Foundation CI passed on ff166df03baa3d9a3c6c83c49c561e0c25b0534f, run 45627627799: Python, Swift, macOS app compilation, bundle and plist verification. No app launch or actual network mutation.
- Added eight literal public contract compatibility fixtures and one public-construction test; explicit constructors for six formerly internal-only models; validated quota profile before policy evaluation. Documented candidate wire encoding and evolution in ADR-0001. New changes require their own exact-HEAD CI. Semantic contract review and owner approval still required before full freeze.
- Staged the changes separately while the preceding CI completed, then advanced the foundation branch without rewriting history. No paid services or release.

## Eleventh iteration

- Completed an engineering review of the eight v1 model semantics, documenting missing aspirational fields and separating observation/planning data from actual authorized execution. Added size, text, date, collection and expiry checks plus five semantic Swift tests. No approval or formal freeze is inferred.
- Added a machine-readable ownership manifest for all 17 current core source files, plus three Python architectural guards. This is not separate SwiftPM targets or an enforced CODEOWNERS permission scheme; shared legacy runtime is still serialized.
- Staged work on test/r4-semantic-review; exact integrated HEAD CI and owner approval are required before scoped freeze. Broad parallel unlock and real network mutation remain blocked. No paid services.

## Twelfth iteration

- Full Foundation CI passed on 374d2e950b61eb14762b81fdb5a966ae8e948481 (run 45628342914): 58 Swift and 12 Python tests, macOS compilation and bundle verification, no failures. This evidence applies to the preceding integration commit only.
- Added UI-independent QuickPanelState/QuickPanelBudget and three unit tests. Unknown/disconnected or external networks do not display a campus balance; native remaining values use GiB and are explicitly local estimates. Native speed text requires a recent measured active-interface sample.
- Added a native SwiftUI menu-bar quick panel using NSHostingController, with separate download/upload budgets, status, refresh, important-work mode, disclosure of forecast/provider/alert settings, and a return to the legacy management panel. Opt-in session preview via the status-bar context menu; the legacy panel stays the startup default until device UX verification. No separate networking or quota logic in the SwiftUI view.
- No screenshot/runtime/VoiceOver evidence yet, no claim of UX-01–08 completion, feature parity, scoped contract freeze or broad parallel unlock. Actual provider policy and host mutation remain blocked. No paid services or distribution.

## Thirteenth iteration

- Added HistoryAnalytics period projection and CSV serialization, with four tests. Seven-, thirty- and ninety-day views cover completed Asia/Taipei dates; missing days are distinct from zero, unknown directional values stay blank, recorded-day mean excludes missing dates. CSV contains only dates, integer byte counts and fixed status labels; no addresses, app names or network identifiers.
- Added native history window and export using SwiftUI FileDocument; reachable from both the native quick panel and the menu-bar context menu. The window reads a bounded SQLite snapshot when opened, not a live update. Export requires explicit user selection and is disabled when the history store reports unhealthy. No per-interface historical breakdown, retention policy or full historical integrity proof yet.
- Staged on feat/r4-history-analytics. Preserve the prior integrated CI until completion; no automatic release, paid service or host-network mutation. Actual UI/file-export interaction and exact-HEAD build must be verified before release.

## Fourteenth iteration

- Native SwiftUI daily stacked traffic chart with period-dependent density, separate upload/download bars, unsplit legacy totals, and distinct missing/recorded-zero markers. Added pure chart projection and two tests covering missing, zero, legacy and single-direction records. The view currently renders from validated HistoryPeriod rows; projection tests do not establish visual correctness or accessibility acceptance.
- Added native settings window for local usage alerts, session-only focus and native preview, menu-bar display preference and persistence status. Changes use existing state and persistence methods, with guarded setters and model synchronization. No mutation switches are offered; changing preview via settings does not open a popover unexpectedly. Launch-at-login, policy configuration and advanced network operations are not added to native settings yet.
- Staged after history analytics on feat/r4-native-settings, retaining the preceding integrated CI if still queued/running. No paid services or release. Exact-HEAD build, runtime export and native UI/device tests remain outstanding.

## Fifteenth iteration

- Added a typed ManagementSnapshot projection and three tests: observed interface order/default route marker, process snapshot freshness and focus suppression, and unknown connection handling. Added native read-only management window with Connections, Applications and Diagnostics tabs, refresh and an explicit campus ranking link. Uses existing sampling, not a new network mutation path. Process values are recent lifetime snapshots, not daily or interface attribution.
- Management view updates while visible; existing optional ping/nettop probes also run while that window is visible, subject to focus/sleep guards. Entry points exist in the quick panel and legacy context menu. No actual network changes, process control or recovery execution. Native automation page remains open.
- Staged on feat/r4-native-diagnostics after analytics and settings. Prior integrated run 45630370273 was still queued during work; do not claim new CI results or real-device verification. No paid services or release.

## Sixteenth iteration

- Added native Automation tab in the existing management window, with alert and focus controls, local estimate tier, per-scope daily alert-attempt status and explicit unavailable network/process mutation features. Added an AutomationSnapshot projection and three unit tests. This completes initial implementation coverage of the seven intended native UI areas, not feature parity or UX acceptance.
- QuotaAlertLedger exports and restores validated scope/tier values in the existing daily state. The ledger is saved before dispatching an alert; a successful write suppresses duplicate attempts after restart. A crash after reservation may omit delivery; failed persistence can allow duplicates after restart. Corrupt ledger blocks today's automatic reminders and persists the invalid marker. Previous versions without a ledger start empty. The status is not proof of macOS notification delivery. Notification subprocess now uses the bounded runner.
- Staged on feat/r4-native-automation. Previous integrated CI remains the gate; no paid services, real network mutation, release or actual UI acceptance. Exact-HEAD CI and real-device checks are pending.

## Seventeenth iteration

- Missing interfaces now emit an unknown interval rather than silently disappearing; invalid sampling clocks cannot seed baselines. Duplicate interface IDs project to unknown rather than crashing the app's dictionary construction. Three accounting regression tests.
- Persist measured sample count (legacy records default to no known evidence). Days with at least one measured interval and zero observed bytes are retained; days with no evidence and zero bytes remain absent. These zero observations are not proof of full-day coverage. Added migration test. Stale prior-day state cannot overwrite already finalized history; failed historical write attempts preserve the daily record or block further persistence, with regression test. Removed raw IP, active interface and hardware baseline fields from newly saved daily state; old backups are not scrubbed.
- Staged on fix/r4-accounting-integrity. The prior native preview CI resumed and passed core tests; integrated app build and the newer candidate require independent verification. No paid services, host mutation or release. Scoped history schema and stronger crash-durable archive transaction still pending.

## Eighteenth iteration

- HistoryStore schema v2 adds an independent history_scopes table, with scope enum validation and atomic aggregate/scope write. V1 totals remain intact, with no retroactive classification. Aggregate-only replacement removes obsolete scope rows, and stale-state recovery does not replace finalized days. New nonzero scope rows must reconcile exactly to directional aggregate totals. Four new regression tests cover migration, classification, reconciliation and CSV scope labels.
- Daily rollover writes the four observed scope buckets (dorm, campusWifi, external, unknown) only for daily states explicitly eligible for the new schema. Legacy or prior-day recovery remains aggregate-only; per-scope zero/coverage cannot yet be inferred, and a missing scope row is not zero. The all-history view may mix historical measurement semantics. Current totals are observations, not campus billing or complete-day usage.
- Native history adds a scope filter for 7/30/90 completed days; scope-specific CSV includes the scope column. No new sensitive identifiers. UI/runtime, crash recovery, exact integrated CI, and true per-scope observation-duration evidence remain outstanding. Staged on feat/r4-scoped-history pending preceding CI. No paid services or release.

## Nineteenth iteration

- SQLite history backup uses the native online backup API, an independent read-only source connection for background export, a private temporary file, bounded backup step loop, and verified non-overwriting publication. No raw copy of a live database. Backup creation does not include today's unfinalized daily state, preferences or other files.
- Read-only backup preflight accepts V1/V2, checks file size, expected tables, quick_check, foreign keys, dates, integer counts, duplicate rows and scope reconciliation. It rejects inconsistent classification and unexpected tables/views/triggers. It is not cryptographic authenticity, complete SQLite sandboxing, a hard runtime deadline or proof of data completeness. Six new regression tests. No restore/import into the active store is implemented or enabled.
- Native Settings exposes user-selected backup and preflight actions, with busy and outcome feedback; operations run in a background queue after selection. Existing destinations are not overwritten. App UI and actual device/file-picker behavior require verification. No paid services or release.
- Staged on feat/r4-history-backup, pending exact-HEAD CI for the preceding integration. Do not claim backup tests passed until verified.
