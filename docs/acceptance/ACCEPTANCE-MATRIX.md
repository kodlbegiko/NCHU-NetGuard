# Local acceptance matrix

No row below is passed by the existence of a script. Device-dependent and privileged operations are not automated. Record exact SHA, date, hardware/OS, preconditions, redacted observations and reviewer. Stop if network availability or existing user work is at risk.

| Gate | Priority | Required evidence |
|---|---|---|
| traffic_accuracy | P0 | Controlled reference, same boundary and interval; both directions ≤1%, zero traffic, >4GiB, resets/hotplug; numeric evaluator is not independence proof. |
| vpn_deduplication | P0 | VPN off/on on authorized network, compare physical and virtual counters separately, prove no duplicate in aggregate; unknown on ambiguous overlap. |
| dual_stack | P0 | IPv4-only, IPv6-only, dual stack, TCP and UDP; distinguish absent family and parser failure, require independent path evidence. |
| network_switching | P0 | Operator switches Wi-Fi/Ethernet or disconnects using macOS UI, verify scope revocation, stale-rate clear, monotonic totals and no unsolicited mutations. |
| sleep_wake | P1 | Operator sleeps/wakes Mac, verify no invented bytes or stale forecast, explicit gap, no process controls. |
| workflow_identity | P1 | Opt-in owned development task; compare independent process identity across exit/restart, verify protected workflow and no process termination. |
| provider_accounting | P0 | Official current policy scope, byte unit, reset, identity, same interval and boundary; absence not safe, compare directions. |
| security_review | P0 | Independent trust-boundary and negative TLS, file alias/race and lifecycle review; fixture tests alone not closure. |
| recovery | P0 | BLOCKED: real mutation adapter disabled; only simulation until separately authorized transactional snapshot and rollback protocol reviewed. |
| performance_idle | P1 | Explicit existing process PID, verify exact binary SHA/provenance, idle conditions, repeated ≥300s samples, CPU <0.5% one core and RSS <80MB; separately inspect child processes. |
| accessibility | P1 | Keyboard, VoiceOver, non-color states, light/dark, display scaling; UX-01–06/08; no unsafe prompts. |
| novice_ux | P1 | ≥5 representative novice sessions; ≥80% unassisted completion of status/quota/pause/diagnosis and zero unsafe consent errors. |
| lifecycle | P2 | BLOCKED for upgrade/uninstall: isolated test install destination, verify no overwrite or data loss, rollback and uninstall; no real user install by runner. |
| soak_168h | P1 | Explicit process read-only monitoring for ≥168 hours with continuous evidence, no unexplained restart or gap; independently review crash/functional behavior. |
| extension | P2 | BLOCKED: entitlement/signing and explicit owner authorization required; no extension activation by runner. |

Each gate requires an independent review; an automatic suite success, numeric threshold, or operator assertion alone never grants release acceptance.
