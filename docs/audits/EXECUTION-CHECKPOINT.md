# Execution checkpoint

- Authoritative integration branch: fix/r4-closure-integration; draft PR #3.
- Last fully passing exact SHA: 99743682f823357aa11b0729e05405b4335830b5; CI 45724841285 (224 Swift, 36 Python; zero failures; both app builds/smoke pass; TCP OK, UDP/host inconclusive).
- Coverage: 3755/3909 = 96.06% on 38/39 sources; alias-only file omitted; new strict declaration-only exclusion pending exact CI.
- Parallel head c716d5988e5de5ca0d58ec717942ffc15a1a8669 introduced measured-zero SQLite v3 history and guarded legacy login-item changes. Candidate 3fe2c00b436e5f58138e7f51fb731df502548b4d preserved at fix/r4-closure-preserved-3fe2c00. Both histories retained in combined integration. Selected existing guarded login configuration rather than introducing duplicate ServiceManagement registration behavior.
- Combined code includes probe allowlist, offline same-boundary traffic evaluator, UI label fixes and coverage classifier. This combined tree requires its own CI; earlier CI is not proof.
- No real host settings, process termination, privileged extension, paid deployment or main merge. No formal unlock or release acceptance.
- Remaining work is in master tracker. User Mac and actual network/provider data unavailable; still-open software tasks are not relabeled blocked.
