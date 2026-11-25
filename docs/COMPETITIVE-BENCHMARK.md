# Competitive benchmark — 2026-11-25

Review basis: public README/documentation and license files, not independent runtime tests or a complete implementation audit. Feature claims are upstream self-descriptions.

| Project | Strength to study | License evidence | NetGuard adoption |
|---|---|---|---|
| [Network Monitor](https://github.com/JohannesMahne/network-monitor) | Live trends, connection budgets, latency and DNS observations, adaptive polling | README states MIT; LICENSE lookup returned 404, verify before copying | Original live trend and latency metrics implemented; configurable connection budgets and probe scheduler pending |
| [NetworkMonitor](https://github.com/kevinabouhanna/NetworkMonitor) | Internet-only accounting, app history, hotspot controls | Apache-2.0 LICENSE | Internet-only accounting and per-app history require validated attribution; mutation controls deferred |
| [NetBar](https://github.com/mh-sudo/NetBar) | VPN awareness, interface selection and display customization | MIT LICENSE | Read-only interface selection, VPN detection and units pending |
| [DataMeter](https://github.com/emmanuelchucks/DataMeter) | Searchable app usage, history, local smoke checks | MIT LICENSE | Search and sort current snapshot implemented; daily per-app history and real-device checks pending |
| [MatrixNet](https://github.com/MatrixReligio/MatrixNet) | Passive connection observation, attribution, historical drill-down | Apache-2.0 LICENSE | Read-only attribution and diagnostics pending; packet capture is not a default requirement |
| [Flowlight](https://github.com/xinbetween/flowlight) | AI tool/process ancestry, evidence-based alerts, tiered history | GPL-3.0 LICENSE | Study features and independently implement; no copied GPL code |
| [Stats](https://github.com/exelban/stats) | Menu bar UX, configuration and release packaging | MIT LICENSE | Study UX and local packaging; paid signing/notarization and release deferred |

No third-party code, images, datasets, or assets imported in this iteration. The existing CC0 license remains unchanged. If code reuse is proposed later, record exact upstream revision, file provenance, copyright and all applicable license/NOTICE requirements; never relabel imported MIT/Apache/GPL code as CC0. Do not add a dependency merely to reproduce a small feature.

## Implemented in this iteration

- Up to 60 seconds / 120 points of session-only measured active-interface download and upload trends, shared chart scale, reset on identity change, missing sample or discontinuous clock; never interpolate unknown measurements as zero.
- Median probe latency and mean absolute change of consecutive successful probe results, not a packet-level jitter or packet-loss estimate. Stale/invalid results are unavailable.
- Search and sorting of the existing current top-20 process snapshot; no new claim of daily or per-interface attribution.
- Five new unit tests. All native UI changes remain subject to compilation and real-device verification.

## Priorities after CI

P0: event-driven route/VPN detection; interface-specific read-only display; validated accounting boundaries (including local/tunnel double-count risks); process deltas with identity and coverage; adaptive optional probes; local smoke testing.
P1: bounded hourly history, source/coverage metadata, explainable diagnostics, per-network budget profiles, AI workload attribution using trustworthy process identity and ancestry.
P2: optional richer passive connections and packet metadata with consent and privacy safeguards.

Do not enable process suspension, firewall rules, real network mutation, deep packet capture, remote lookups, or paid services as a side effect of benchmarking. 

## Iteration 25 — network observation

- NetBar-inspired read-only physical-interface rate display and filtering; selection never changes default routing, accounting buckets, or quota. A vanished interface remains explicitly unavailable. Tunnel-name hints are not verified VPN status, and tunnel counters remain excluded from the physical accounting path.
- NWPathMonitor path events invalidate stale route/ping observations and schedule coalesced IPv4 discovery, with 10/30-second visible/hidden fallback. Event detection is best-effort, not complete VPN or IPv6 route attribution.
- Network Monitor-inspired adaptive optional probes: visible busy/quiet ping cadence 15/45 seconds, app snapshot cadence 10/25 seconds. Hidden views do not schedule these optional probes; explicit refresh/open events and provider polling remain separate. Focus/sleep guards remain in force. Core accounting remains at one second. No energy savings measured yet.
- Four new regression tests. LAN-versus-internet exclusion, per-process counter deltas, custom quotas, real device smoke testing and verified VPN attribution remain open. No imported third-party source or new permissions.

## Iteration 26 — observed process usage

- DataMeter/NetworkMonitor-inspired directional process deltas: pair nettop counters only for matching PID/name and ps lstart observed before and after sampling. Separate the original lifetime-counter snapshot from observed session totals. No accumulation of raw lifetime values, no daily or per-interface attribution, and no writes of process names/PIDs to disk. A same-second PID reuse, unsupported nettop column layout, counter semantics, short-lived processes and incomplete sampling remain limitations; host fixture verification is required.
- Bounded process accumulator (4096 sample rows, 1024 display names, 45-second maximum pairing interval), checked arithmetic, focus/sleep/hidden observation discontinuity handling, separate download/upload display, search/sort, and four regression tests. Visible probes add up to two bounded ps queries; CPU and battery overhead are not yet measured. Short hidden transitions between scheduler ticks may be missed.
- Per-app persistent daily/hourly history and stable executable/bundle attribution remain pending. Do not label session observations as provider billing, complete daily usage or Internet-only traffic. No third-party code copied.

## Iteration 27 — opt-in process history

- DataMeter/MatrixNet-inspired daily and hourly observed process usage, grouped by Taipei calendar date/hour. A separate accumulator starts a new bucket at each hour boundary or wall-clock discontinuity; a crossing interval is deliberately not attributed. Session/hour cumulative snapshots replace only monotonic prior snapshots and identical retries do not double count. Independent sessions coexist across restarts.
- Local JSON store per calendar day, separate from the SQLite quota/history store. Files are limited to 2 MiB/day and 512 session/hour snapshots, with validated dates, unique identities, bounded labels, checked arithmetic, atomic replacement, and explicit read/write failure status. One serial caller is required; no cross-instance locking or fsync guarantee. Existing corrupt files are not overwritten. No automatic retention or deletion yet; cumulative disk use can grow across days.
- Persistence is opt-in for the current app run, off after restart; disabling stops new records but retains previously stored labels. No PID, start time, IP, destination or executable path is intentionally persisted. Names themselves may reveal user activity. Native management includes today/yesterday and 24 hour filters, measured interval count, separate upload/download, and existing search/sort. Empty buckets and missing data remain distinguishable. Other date ranges, CSV, privacy deletion controls and backup integration remain pending.
- Four regression tests. Runtime capture layout, actual file permissions, multi-instance behavior, UI interactions, and energy/I/O cost still need local verification. No copied third-party code, new paid dependencies or host network mutation.

## Iteration 28 — process history privacy and responsiveness

- Added opt-in history retention options (7/30/90 Taipei calendar days, default 30, session-only configuration). Pruning happens after successful writes only; future-dated files, unrelated names, directories and symlinks are excluded. Explicit confirmed deletion stops recording and clears recognized history files, without changing the SQLite traffic ledger. Deletion is not secure physical erasure and may be partial on I/O failure.
- Moved history read/write/prune/delete operations to one serial utility queue with at most one in-flight operation. Skipped samples break history continuity; UI reports busy/failure states. No cross-instance locking, crash-durability guarantee, or measured performance gains. Added three regression tests.

## Iteration 29 — personal budgets and speed units

- Network Monitor-inspired personal daily total budget for one existing accounting category (dorm, campus Wi-Fi, or aggregate external), 1–10000 decimal GB, optional and persisted locally. Explicitly independent of official policy, automation, alert ledger, routing and historical records. Category totals are partial observations, not subscription balances; no individual hotspot/SSID identity or monthly billing period yet. All-zero categories remain unavailable until category-specific coverage exists.
- NetBar-inspired selectable binary byte/s or decimal bit/s formatting in the status bar and quick panel speed text; other charts and historical units are unchanged. Three unit tests added. No imported code or paid dependencies.
- Remaining adoption priorities: source-verified per-network identity and monthly/custom reset budgets, LAN/Internet separation, stable bundle/AI-agent attribution, DNS and loss diagnostics, complete backup restore, and local smoke tests. Do not claim implementation parity before device evidence.

## Iteration 30 — quality diagnostics

- MatrixNet/Network Monitor-inspired ICMP echo non-response ratio based on completed probe counts and weighted mean RTT; malformed, incomplete, expired and failed probes are unavailable rather than fabricated zero or 100% loss. Up to ten probes over 180 seconds; latest evidence expires after 120 seconds. This is target-specific ICMP evidence, not Internet-wide packet loss.
- Explicit manual DNS test using dig's default resolver for example.com, reporting response status and query time, not proving application/system resolver success. No periodic DNS traffic. Route, sleep and generation invalidation prevent stale results. Four regression tests. Existing ping scheduling and quota accounting remain independent. No imported source or paid services; exact device command output and UI behavior remain unverified.

## Iteration 31 — AI workload attribution

- Flowlight-inspired AI workload view implemented independently. Two existing ps identity probes now also collect PPID and comm, without argv/environment capture. Match the complete ancestry through the nearest recognized executable basename before and after nettop; a changed ancestry breaks the delta baseline. Recognized labels: Codex, Claude/Claude Code, Cursor, Ollama, LM Studio. No fuzzy substring matching or generic node/python classification. Names are hints, not code signature or bundle identity verification.
- Separate in-memory directional usage accumulator and native AI tools mode, with explicit overlapping-subset semantics (never add this to ordinary process totals). No disk persistence of paths, ancestry or AI attribution. Detached services, shared network helpers, renamed executables, remote tasks, short-lived processes and same-second PID reuse remain unresolved. Actual ps/nettop format and resource cost need local macOS evidence. Four regression tests; no third-party source or paid dependencies.

## Iteration 32 — optional background process monitoring

- DataMeter/NetworkMonitor-inspired opt-in background process sampling, separate from disk-history consent, default off after each launch. When enabled, hidden views sample at 20 seconds during higher observed throughput or 35 seconds otherwise; visible cadence remains 10/25 seconds. No new periodic DNS/ICMP probes when hidden. Focus/system sleep override consent; no sleep prevention or auto-start changes.
- Native process view shows monitoring state and cumulative duration of intervals with at least one successfully paired process; AI view shows its own paired duration. This is not complete process coverage or a verified daily usage total. Existing optional local history can receive background samples when separately enabled. Two regression tests added. Probe cost, sleep/wake behavior and macOS output still require local acceptance; no third-party code or paid dependencies.

## Iteration 33 — dual-stack evidence

- Added separate IPv4 and IPv6 default-route interface discovery using fixed read-only route invocations. Displays different route interfaces and tunnel hints across both families; unknown/stale results remain explicit. IPv4 address-dependent campus provider, quota and probe logic stays unchanged. No claim of verified VPN identity, reachability or complete IPv6-only functionality.
- Per physical interface, display IPv4 and IPv6 address-family observations and distinguish link-local-only IPv6 from non-link-local addresses. No additional counter collection, address display or persistence, LAN/Internet classification, route changes, or double counting by protocol. Non-link-local includes ULA; it does not imply a globally reachable address. Route event/sleep invalidation and 60-second freshness; sequential family probes are not an atomic route snapshot. Four regression tests added. Actual macOS route output and IPv6-only behavior remain to be verified.

## Iteration 34 — explicit connection-session budgets

- Added independently named, user-started, in-memory connection session meter for the currently observed physical interface. Decimal GB budget, directional bytes, measured intervals and remaining estimate. Discard first interval after Start; stop permanently on changed interface/identity/scope, missing or duplicate sample, invalid delta, route event, sleep, calendar rollover or arithmetic overflow. Starting again replaces the prior session. The meter consumes existing measured deltas only and does not change quota policy, routing or aggregate ledgers.
- This is a conservative session subset, NOT a persistent network identity or individual subscription ledger. Same-address network changes may not be observed, and IPv6 address churn may stop a valid session. LAN traffic remains included. No persistence, SSID collection, automatic reconnection attribution, billing-cycle matching, or guaranteed VPN/LAN separation. Four regression tests; runtime correctness still needs local testing. No imported third-party code or paid service.

## Iteration 35 — manually saved connection history

- Added a separate local archive of explicitly saved, stopped connection sessions, with UUID identity, user label, save timestamp, directional observed bytes, budget and interval count. Identical retries are idempotent; different sessions with the same label are never merged. No automatic persistence, stable network identity, reconnect matching, LAN exclusion, billing-period aggregation or hardware identifiers.
- Native management includes expandable history, manual save/read, and per-record confirmed deletion. Serialized utility-queue I/O, bounded 1000 records / 2 MiB, validation and atomic replacement; corrupt files remain untouched. No automatic retention, multi-process locking, secure erasure or backup integration. Timestamp is save time, not the connection start. Four regression tests added. Device behavior and exact candidate CI remain unverified.

## Iteration 36 — monthly and custom cycle budget worksheet

- Network Monitor-inspired budget projection for explicitly selected archived connection sessions. Monthly anchor 1–31 clamps to each month's last calendar day, including leap years; custom inclusive start/end dates use Taipei time. Decimal GB limit, directional sums, remaining estimate, unique record IDs and checked arithmetic. Empty selection is unavailable rather than zero usage; missing/deleted or out-of-period selection is rejected.
- Native expandable worksheet with monthly/custom period, record toggles and progress. The archive only records save time, not measured interval start/end, so filtering is explicitly by save date and requires user confirmation of actual usage period. Same labels are never automatically merged. Worksheet is session/view state only, not a persistent billing profile or automatic quota enforcement; no network identity collection or historical reclassification. Four regression tests added. No third-party code or paid dependencies. Exact candidate CI and device UX remain unverified.

## Iteration 37 — explainable traffic events

- Flowlight-inspired evidence-based local event timeline implemented independently. Active-interface combined rate uses existing measured deltas only. Sustained high flow is at least 5 MiB/s for 10 seconds of contiguous samples; a surge requires at least 20 preceding observations spanning at least 20 seconds, at least 1 MiB/s and at least four times the preceding median, with a 60-second repeat cooldown within the same continuity window. These are heuristic observations, not security or policy-violation determinations.
- Missing/invalid samples or discontinuous monotonic time produce a gap event after a previously observed interval. Route, sleep, day and identity boundaries reset continuity instead of inventing usage. Native diagnostics lists up to 100 in-memory events with time, observed rate, baseline/duration and confirmed clear. No disk persistence, notification delivery, packet inspection, network mutation or process control. Thresholds are fixed initial heuristics, not calibrated against actual devices. Four regression tests added.

## Iteration 38 — configurable event rules

- Native diagnostic rules editor supports sustained rate 1–1024 MiB/s, duration 5–120 seconds, minimum surge rate 1–1024 MiB/s and surge factor 2–20. Validated local preferences persist across launches; invalid stored settings fall back to standard rules. Default reset and explicit apply. Changed rules reset the detector baseline and preserve prior events. Existing event records do not snapshot historical rule configuration; the displayed current rule must not be interpreted as the historical trigger threshold.
- Three regression tests added for validation, continuity and configured surge. No automatic blocking, notifications, disk event history or calibrated performance claims. CI for the preceding integrated SHA became visible as run 45641149215; static/Python and Swift stages passed, app build underway at last check. Candidate still staged pending exact verification.

## Iteration 39 — event evidence archive

- Each new event includes its historical rule snapshot, validated against its kind and observed rate, duration or baseline. Manual local archive supports save/read/clear, UUID idempotence, bounded 1000 records and 2 MiB, and corruption preservation. Native diagnostic views distinguish live and saved events and display trigger-time rules. Serialized utility-queue I/O. No automatic disk recording, IP, process labels, destination data, notifications, network changes, or policy-enforcement claims. No cross-process locking, automatic retention or integrated backup. Four tests added. Prior CI run 45641149215 passed all steps; candidate requires exact-HEAD validation and local acceptance.

## Iteration 40 — portable multi-store history backup

- Fixed a missing try in the monthly anchor calculation after exact integrated CI 45642942716 failed during Swift compilation. The one-commit repair d3c9a622691081dec999d52914c69e64dbb8aff3 was fast-forwarded to the integration branch; repair CI 45643262817 started.
- Added a portable directory export of the SQLite history snapshot and validated saved process-day, connection-session and traffic-event records, with versioned SHA-256 manifest, fixed path inventory, size limits, staging and non-overwriting publication. Native settings expose export and read-only preflight; optional history writes are paused within the current app during export. Core traffic monitoring remains active. Three regression tests cover roundtrip, existing destination, tampering and source corruption.
- This is a history-only, independently sampled bundle, not a simultaneous application snapshot, signed provenance, encryption, secure storage guarantee or active-store restoration. Excludes current unsettled traffic, settings, unsaved observations and recovery journals. No multi-process locking or guarantee against concurrent external filesystem changes. A manifest detects accidental payload changes, not deliberate modification of both payload and manifest. Exact candidate CI and native file-dialog behavior remain unverified.
