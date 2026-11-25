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
