# NetGuard threat model (R4.0 initial)

## Assets and trust boundaries
Local usage/history, network configuration and existing connections, user authorization, application state, and provider data. Untrusted inputs include provider HTML, network responses, interface/command output, WebView messages, persisted legacy state, and process names. Never equate a process name or missing provider row with a violation or safety.

## Threats and controls
| Threat | Mitigation / current state |
|---|---|
| MITM or forged provider | Default TLS trust enabled; explicit unknown on failure; fixture-verified parser still required |
| Privilege abuse / command injection | Network mutations disabled in foundation; future adapter must allowlist arguments, validate target identity and consent |
| Unrecoverable config change | No legacy mutation or automatic restoration without a trusted snapshot; transactional journal and rollback are open gates |
| Process data loss | No automatic terminate/kill/freeze; notification-only |
| Untrusted UI input | Main-frame bundled local URL check; bridge still requires full isolation review and typed messages |
| Privacy leakage | No new telemetry; redact diagnostics and avoid committed private identifiers; data retention controls pending |
| Misleading counters | Show local estimate; multi-interface pure engine prototype not integrated; reset/missing/duplicates unknown |
| Resource exhaustion | Background speed probes gated off; timeout and subprocess lifecycle hardening remains open |

Release blockers: validated provider identity/freshness, atomic recovery, authorization, real-device verification, and CI evidence. CI never mutates routes or launches the app. No paid integrations, root daemon, special entitlement, or external release is authorized in this stage.
