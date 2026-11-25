# Security audit — partial, evidence-based

Scope: R4–R6. Last fully passing implementation candidate: 517fb31ffcd58ef8482af8f4d483bf96c2a40cad; [CI](https://github.com/kodlbegiko/NCHU-NetGuard/actions/runs/45724245114). This report is an interim findings register, not a certification or closure of P0-D.

| Boundary | Implemented evidence | Remaining verification / risk |
|---|---|---|
| TLS and redirect | Standard trust; explicit error category; no silent successful fallback on malformed ranking | Independent negative TLS/redirect integration fixtures, official source evidence |
| Shell and command execution | Fixed absolute probe paths, argument arrays, bounded stdout, time limits; no shell in ProbeRunner | Lifecycle of non-cooperative child/descendant; audit every caller; device behavior |
| WebView and XSS | Existing bridge safety/static guards; unknown scope and stale observations remain explicit | Full origin/source and injection review, interactive adversarial UI checks |
| File races, symlinks, hardlinks | Daily state compare-and-replace under cooperating stable lock, descriptor-relative read, private temp file, sync; SQLite final NOFOLLOW | Non-cooperating same-user races, hardlink coverage throughout storage, ancestor path replacement, complete multi-store transaction |
| SQLite | Schema introspection and migration in write transaction; trusted_schema OFF; reject unexpected shapes and triggers; backup inspector bounded VM work | Full adversarial database corpus, busy/corruption/restore failure tests and post-open schema mutation |
| Process attribution | Calendar validation, duplicate PID rejection, lineage cycle rejection; heuristic labels only | Kernel-backed identity, code signatures, PID generation and short-lived process coverage |
| Input/resource limits | Bounded provider, probe, rule and journal input; validation; stable invalid/unknown states | Complete cross-module resource exhaustion review, long-run performance |
| Automation and authorization | Native rule editor only produces dry-run recommendation; simulator uses fixture/in-memory state; no system mutation or external process control | Real authorization gate, allowlisted adapter, timeout/cancellation and transactional device rollback; activation remains prohibited |
| Sensitive data | Flow outputs aggregate and redact peers/processes; route candidates retain ephemeral next-hop only within manual observation | Independent privacy/log/export review across all paths, real device consent |
| Recovery | 14 explicit simulated fault modes, 15 scenario matrix, two restart tests | Enumerate remaining fault combinations and actual hardware rollback; do not infer device success from simulator |

The earlier NOFOLLOW incompatibility on macOS system temporary parents was reproduced by CI 45723912849, resolved by canonicalizing the parent while retaining final-component NOFOLLOW, and rerun without removing tests. Future real system mutation requires separate explicit authorization and validation. No broad parallel unlock, release or security certification is implied.
