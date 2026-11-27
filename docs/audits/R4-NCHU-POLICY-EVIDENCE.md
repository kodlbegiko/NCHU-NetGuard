# NCHU policy evidence (2026-11-26 Asia/Taipei)

- [CINC quota FAQ, 2023-11-30](https://cc.nchu.edu.tw/p/406-1000-788%2Cr36.php?Lang=zh-tw): per-IP daily campus 10G down/5G up; dorm 7G down/4G up. Directional excess causes throttling; dorm excess-traffic exemption unavailable.
- [Campus network FAQ](https://networkqa.email.nchu.edu.tw/%E6%A0%A1%E5%9C%92%E7%B6%B2%E8%B7%AFfaq): confirms 10/5 and 7/4, next-day recovery, external network throttling.
- [CINC traffic FAQ](https://cc.nchu.edu.tw/p/406-1000-784%2Cr36.php?Lang=zh-tw): hourly statistical update, distinct from HTTP retrieval time.
- [CINC current lookup links](https://cc.nchu.edu.tw/p/406-1000-787%2Cr36.php?Lang=zh-tw): provider ranking and violation/disconnection lookup are separate.

These sources support published limits and hourly update, not exact bytes-per-G, billing reset timestamp, per-dorm applicability, current provider HTML schema or host identity mapping. Other campus documents have reported different limits; scope-specific policy confirmation is still needed. Do not mark units verified, convert provider ranking into local totals, equate a campus IP with dorm membership, or infer a safe/block state from absence. Provider/device reconciliation remains open.

## Reconciliation candidate

NetGuardProvider now has an explicit comparison API requiring independently verified ephemeral identity and boundary tokens, matching measurement windows (not retrieval time), verified bytes, complete coverage, fresh evidence and both directional counters. Differences remain directional integer magnitudes, never a quota balance. A ranking string cannot create this evidence; actual NCHU adapter and official accounting remain unresolved. Invalidated failed requests retain exponential backoff and invalid calendar days cannot become fresh. Regression tests accompany the implementation; exact CI required.

## 2026-11-28 policy conflict recheck

- The CINC Chinese FAQ (2023-11-30) and [English FAQ (updated 2024-12-05)](https://cc.nchu.edu.tw/p/406-1000-921,r36.php?Lang=en) both state campus 10G down/5G up and dorm 7G down/4G up. The Chinese text identifies excess as throttling, not necessarily disconnection.
- The indexed text of [female dormitory rules, Article 12](https://www.osa.nchu.edu.tw/osa/dorm/rules/07-1140820.pdf) instead states 8G down/5G up and next-day speed recovery at 05:00. The PDF screenshot fetch returned 404 during recheck; document applicability and current availability are not established. Do not generalize to every dorm, and do not confuse recovery time with accounting reset time.
- Keep the existing local configured 7/4 and 10/5 estimates unchanged pending written CINC confirmation of applicable limits, exact byte unit, metering boundary, IP mapping, accounting timezone/reset, and ranking update time. Do not treat the estimate as a guarantee of quota compliance. No automatic network mutation, quota exemption, or increased allowance is authorized by these conflicting records.
