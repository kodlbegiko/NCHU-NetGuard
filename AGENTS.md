# NetGuard engineering instructions

Read docs/ROADMAP.md, docs/UX-PRINCIPLES.md and docs/contracts/v1.md before changing code.
- Free/local-first only: no paid API, paid runner, deployment, notarization, paid signing or service activation without owner approval.
- Main is stable baseline; use feature branches and PRs. Do not merge unverified changes.
- No root daemon, arbitrary shell, TLS bypass, unapproved process termination, or policy evasion. Legacy mutation paths are disabled in R4.0 safe mode until authorization + transactional rollback + real-device tests exist.
- All unknown/stale provider data stays unknown; never label a missing row or failed request as safe.
- Keep user-specific paths, IPs, secrets and personal logs out of source/fixtures. Use reserved test addresses.
- Run make test, swift test, make build on macOS. CI must not launch the app or alter host network settings. Record exact commit and actual results; distinguish local, CI and real-device evidence.
- Contract changes require an ADR and tests. Do not claim parallel unlock or release readiness while P0/P1 gates remain open.
- Module ownership and milestones follow ROADMAP; document any scope changes, regressions and known blockers.

- UX is simple-first, powerful-engine: default to readable status and recommended actions, progressively disclose advanced controls, never conceal unknown data or unavailable actions. Every user-facing change must follow docs/UX-PRINCIPLES.md and its acceptance gates; no extra steps unless needed for safety or consent.
