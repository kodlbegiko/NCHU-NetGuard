# NetGuard UX constitution — simple operation, powerful engine

Status: product requirement, not implementation or verified UX. Applies to R4.0 onward, including R4.3 Native Experience.

## Product principle

**操作簡單直觀，底層功能強大。** The user should manage outcomes, not network primitives. The engine may be sophisticated; the main interface must remain calm, predictable, native and comprehensible. Do not delete useful capabilities merely to simplify the front page; reveal complexity progressively. Never conceal uncertainty, consent, risk or failed actions.

## Three layers

| Layer | Audience | Contents |
|---|---|---|
| Menu bar / quick panel | Everyone | Network identity and connection, separate remaining upload/download budgets with freshness, protection status, one recommended action or explanation |
| Main window | Everyday users | Overview, Analytics, Connections, Applications, Automation, Diagnostics; simple task-oriented labels, short explanations |
| Advanced settings | Power users | Rules, thresholds, per-network policies, detailed diagnostics, audit logs, export and recovery; off the default path |

Opening the app must not require knowledge of IP, subnet, DNS, route priority or system extensions. Advanced controls are optional and discoverable, not required onboarding.

## First-run and routine interaction

1. Start in read-only observation mode with no privileged action or account sign-in. Explain what is observed locally and what is not yet known.
2. Detect candidate network environment, show confidence and ask for confirmation only if necessary. Never assume a private IP is a campus network.
3. Show meaningful live estimates, download and upload remaining, and data quality. Unknown is not zero, not unlimited, and not safe.
4. Provide a recommended next action with a reason. Default to passive monitoring; enable automation only with informed opt-in, verified platform support and recovery.
5. Keep one master automation pause and an accessible recovery entry. Pause must not silently stop monitoring or destroy configuration.

When protection cannot be enabled, state why and how to resolve it. Never display an enabled switch or success banner for an unavailable operation. A one-click action can open a confirmation or preview when risk is material; simplicity does not override authorization.

## Main view information hierarchy

- Primary: current network, actual status (observing, active protection, paused, unknown, action unavailable), estimated remaining download/upload and timestamp.
- Secondary: current speed, usage trend, high-traffic application if attributable, and contextual recommendation.
- Tertiary: historical charts, diagnostics and advanced automation. Do not place all settings on the quick panel.

No fabricated initial latency, throughput, remaining quota or risk. Show loading, offline, stale, permission denied, unsupported and failure states explicitly. Use plain-language labels first, technical detail on demand. Provider estimates and local counters must be distinguishable.

## Automation UX

- Default: observe and recommend. No automatic route writes or process termination until safety gates pass.
- Future opt-in: explain proposed action, why, network affected, potential disconnect/data cost, workflow protection, and rollback readiness.
- Confirm meaningful changes, verify postconditions, then show outcome. If action fails or conflicts, provide a clear safe-mode explanation and recovery options.
- Advanced rule editor must have templates, dry run, conflict detection, explicit priority, and understandable event history.
- Respect school/network rules and user consent; no bypass-oriented messaging.

## Native design and accessibility

Use macOS native menu bar and SwiftUI/AppKit where feasible; support light/dark appearance, keyboard navigation, VoiceOver, dynamic text, reduced motion and non-color-only status indicators. Compact panel should adapt to screen bounds rather than fixed tall layout. Avoid unnecessary animated indicators, dense grids and persistent banners. Prefer contextual progressive disclosure.

## UX acceptance gates (proposed, not measured)

| ID | Gate |
|---|---|
| UX-01 | Fresh launch reaches read-only monitoring with no mandatory technical configuration or privileged prompt |
| UX-02 | Core status and separate upload/download remaining visible on first panel without scrolling on supported displays |
| UX-03 | User can find main status in one interaction, history and settings within two interactions from menu bar |
| UX-04 | Unknown/stale/unsupported/failed states cannot render as healthy, unlimited or successful |
| UX-05 | Pause automation is one accessible action; recovery entry is clearly discoverable; destructive/mutating action requires appropriate consent |
| UX-06 | Basic tasks remain usable with keyboard and VoiceOver, without relying on color |
| UX-07 | At least five representative novice usability sessions before stable release; target >=80% unassisted completion of status, quota, pause and diagnosis tasks, no unsafe consent errors |
| UX-08 | No user-facing claim beyond verified capability; advanced functionality remains accessible without cluttering the default panel |

Measurements require evidence, device, OS, task script and results. Any exception needs an ADR. Keep this spec independent of paid services, paid testing tools, external telemetry and publication.
