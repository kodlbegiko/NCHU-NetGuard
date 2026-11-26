# Round 4 device evidence — 2026-11-26

Source: operator-supplied redacted report, not independently authenticated raw logs.
Tested source: `16e28183bd0af9e582c0023536178f67fa597b0b`, clean at start/end, same revision at end.
Candidate executable SHA-256: `0c6a8e7d5a50fa113795dc1db5efa54971fb12385e9347b7bfa78f1a1ccb364f`.
Reported environment: macOS 27.0.1 / arm64, Mac16,12, Swift 6.4.2, Python 3.14.7.
Independent hosted CI: [#213](https://github.com/kodlbegiko/NCHU-NetGuard/actions/runs/45827107005), completed success at tested source SHA.

## Automated host profile

Reported automatic_exit_code=0, VERIFY_EXIT=0, 12/12 planned steps pass, 11/11 log digests match. Core coverage 4276/4466 (95.75%), inventory complete. Preflight, toolchain, Python/Swift tests, coverage, both builds, both fixture smokes, host compatibility, TCP and UDP observation all pass. Host observation is not independent proof of traffic accounting, IPv6-only operation or VPN deduplication.

## Idle measurements

Operator reports isolated temporary HOME, ten-second settling period, 60-second soak trial then 300-second idle benchmark, no user interaction, zero child processes at beginning/end. Transient child processes are not excluded by endpoint counts.

| Round / tested SHA | 300s mean one-core CPU (%) | Peak RSS (bytes) |
|---|---:|---:|
| 1 / 4cf399a2 | 1.6298 | 88702976 |
| 2 / 26b35717 | 0.9399 | 106971136 |
| 3 / ccb6cc69 | 0.7366 | 60522496 |
| 4 / 16e28183 | 0.2566 | 55410688 |

Thresholds unchanged: CPU strictly below 0.5%, RSS strictly below 80000000 bytes. Round 4 numeric observations meet both. End RSS 55230464 bytes. Five relative-window CPU readings: 0.2815%, 0.2649%, 0.2484%, 0.2484%, 0.2395%; RSS approximately 54.4–55.4 MB across windows; peak reported at 191.2s. 60s short soak CPU 0.2332%, max RSS 60768256 bytes, no reported gaps. Short-window stability is not proof of zero leaks. The required repeated >=300s benchmark, independent provenance review and child-process review remain outstanding. No completed 168h run.

## Manual gate status

Reported ledger verification: 5 evidence files, local_consistency_only_not_authenticity.

| Gate | Priority | Reported outcome |
|---|---|---|
| performance_idle | P1 | observed_pass; repeat and independent review required |
| dual_stack | P0 | inconclusive |
| provider_accounting | P0 | inconclusive |
| security_review | P0 | inconclusive |
| soak_168h | P1 | inconclusive |
| traffic_accuracy | P0 | not_run |
| vpn_deduplication | P0 | not_run |
| network_switching | P0 | not_run |
| sleep_wake | P1 | not_run |
| workflow_identity | P1 | not_run |
| accessibility | P1 | not_run |
| novice_ux | P1 | not_run |
| recovery | P0 | blocked |
| lifecycle | P2 | blocked |
| extension | P2 | blocked |

Totals: 1 observed_pass, 0 observed_fail, 4 inconclusive, 7 not_run, 3 blocked. full_device_acceptance=false, review_status=review_required. No formal parallel unlock or release acceptance. Do not change runtime merely to improve already passing idle metrics; prioritize outstanding P0/P1 implementation and controlled device evidence. Preserve current acceptance thresholds. Repeat the idle measurement for final closure and verify cache invalidation through actual network switching/hotplug; do not activate blocked operations. This record is documentation-only and does not extend tested SHA claims to later source revisions.
