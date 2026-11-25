# Execution checkpoint

- Authoritative cumulative branch: fix/r4-closure-integration; draft PR #3.
- Code HEAD before documentation/coverage classification checkpoint: d6154369bd5b22fb441e6f396961ec1f8dd91d7e.
- Last fully passing exact code SHA: 99743682f823357aa11b0729e05405b4335830b5.
- CI: https://github.com/kodlbegiko/NCHU-NetGuard/actions/runs/45724841285 (success). 224 Swift + 36 Python tests, zero failures. Both builds and fixture smoke pass. TCP compatibility evidence OK, host parser and UDP inconclusive (non-gating, not device acceptance).
- Coverage 3755/3909 executable lines = 96.06%, 38/39 production Swift files reported. Inventory incomplete because alias-only ModuleCompatibility.swift omitted. The new verifier narrowly excludes this exact path only if all lines are imports, typealiases or the expected conditional directives/comments. Re-run exact CI; do not infer the target is already closed.
- Subsequent implementation commits: 672ae2a login/menu safety; 3f2cbe5 controlled traffic evaluator; d615436 production probe argument allowlist. These and the new coverage exclusion are NOT included in the last successful CI.
- Earlier failed CI 45723912849 reproduced and fixed at 517fb31, verified by CI 45724245114 (222 Swift + 35 Python).
- User Mac working tree not inspected. Linux connector cannot provide real macOS hardware, official accounting, authorized device rollback or 168-hour soak.
- Remaining engineering: exact CI and coverage evidence, full runtime contract consumers and owner review, independent route/billing attribution and real device measurements, recovery authorization and adapter, identity/signature and workflow, unified history/restore, policy scheduling and UX, R5 lifecycle and R6 provider/plugin/CLI/API/MCP. Unimplemented items remain open, not externally blocked.
- Main unchanged; no merge, release, deployment, paid service, real network mutation, or privileged extension activation.
