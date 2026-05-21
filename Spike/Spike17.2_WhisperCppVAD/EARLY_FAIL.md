# EARLY-GATE FAIL — Spike #17.2

## Verdict

EARLY-GATE FAIL on C4, C5, C6, C8 with whisper-small on Metal (M3, macOS 26).
NO-SKIPPING rule did NOT trigger (C4 = 333–440ms, < 2000ms 10× threshold).

## Measured values

- **C4**: 333–440ms first-token latency (budget ≤200ms, 1.67×–2.2× over)
- **C5**: p95 inter-update gap = 1985ms (budget ≤800ms, 2.5× over)
- **C6**: 32 ghost tokens on silence_only fixtures (budget: 0)
- **C8**: 0/6 silence boundaries detected (budget ≥5/6 = 83.3%)

See results/EARLY_summary.json for full scorecard.
See REPORT.md for root cause analysis and tuning recommendations.
