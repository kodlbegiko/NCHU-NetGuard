# QA coverage map — candidate, not acceptance results

All rows remain unverified for the current device. The unattended observer
does not enable system changes, generate campus traffic, or issue release approval.
"Integrated" means a mechanism exists, not a test pass.

| # | Requirement | Candidate mechanism | Remaining evidence |
|---|---|---|---|
| 01 | App heartbeat | Opt-in 5s private heartbeat | Device run |
| 02 | Main thread stall | Tick gap and duration, stale heartbeat | Fault reproduction |
| 03 | Background timeout | Route/app/ping/provider/DNS busy ages | Other manual-operation queues |
| 04 | Crash/exception | Process continuity, matching report index | Report attribution/inspection |
| 05 | Sample stalled | Cycle counters and age | Independent traffic |
| 06 | Zombie/child residue | Sampled descendant tree | Detached/reparented processes |
| 07 | Memory growth | RSS/footprint trend | Independent leak analysis |
| 08 | CPU spikes | 5s idle / 60s soak interval CPU | Subinterval peak not captured |
| 09 | Disk I/O | Darwin rusage v2 | Host API availability |
| 10 | File descriptors | lsof numeric FD count | Trend review |
| 11 | Threads | ps thread rows, nullable | Host compatibility |
| 12 | Child resources | Descendant RSS/count | Child CPU attribution |
| 13 | UI latency | Four fixture construction/layout timings | Real panel interaction ≤300ms |
| 14 | Energy/wakeups | Darwin wakeup counters | Actual energy measurement |
| 15 | Controlled reference | Existing numeric evaluator | Independently measured physical boundary |
| 16 | Zero/low traffic | Deterministic fixtures and measured-zero stress | Physical traffic |
| 17 | High traffic/overflow | Seven-day synthetic 604800 ticks + ceiling fixtures | Physical traffic |
| 18 | VPN dedup | Existing policy/flow fixtures | Authorized VPN off/on reference |
| 19 | IPv4/v6 TCP/UDP | Host probes/fixtures | Actual family/transport coverage |
| 20 | Offline/recovery | Fixtures and health detection | Real authorized disconnect |
| 21 | Multiple NICs | Synthetic dual source and fault transitions | Actual NIC switch |
| 22 | DNS/TLS/HTTP | Existing negative fixtures, live busy flags | Independent negative TLS review |
| 23 | SQLite integrity | Bounded hourly read snapshot | Device execution |
| 24 | Ledger consistency | Direction/scope reconciliation | Independent source comparison |
| 25 | Midnight | Observed day transition and retained lower bound | Exact finalization completeness |
| 26 | Database growth | Hourly size trend | Retention review |
| 27 | Backup/restore | Existing isolated lifecycle and data tests | Actual cross-store restore |
| 28 | Automation/notifications | Existing fixture tests, repeated every 6h | Delivery and real policy review |
| 29 | AI workflow | Existing identity/consent fixtures, periodic regressions | Real opted-in owned task |
| 30 | Fault injection | Existing recovery fixtures, synthetic faults, repeated regressions | Real authorized adapter remains blocked |

Full seven-day run requires core/host report, two build fixture checks,
isolation and version identity evidence, three idle windows, heartbeat-bearing
soak, periodic diagnostics and all 28 six-hour regression cycles. Unsupported
observations remain unknown. This map does not replace ACCEPTANCE-MATRIX.md.

## Gating self-test
Both built binaries must emit the actual heartbeat producer fixture and reject a recovered safety hold and existing report replacement. Local IPv4/IPv6 TCP/UDP echo fixtures validate known payloads without campus traffic; IPv6 unavailability remains review-required. Final v3 report explicitly inventories evidence gaps, including normal-mode performance; full device acceptance remains false.
