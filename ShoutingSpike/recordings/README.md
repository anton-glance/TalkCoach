# ShoutingSpike Recordings

Record 5 clips and place them here as `.caf` files.

## Clips

1. `quiet_normal.caf` — Quiet room, ~20s, normal-volume speech. No shouting.
2. `quiet_shout.caf` — Quiet room, ~20s total: ~12s normal speech, then shout for ~5s.
3. `noisy_normal.caf` — Noisy room (HVAC, fan, or cafe noise), ~20s, normal speech. No shouting.
4. `noisy_shout.caf` — Noisy room, ~20s total: ~12s normal speech, then shout for ~5s.
5. `transition.caf` — ~30s total: ~10s quiet with normal speech, then ambient noise turns on, continue normal speech ~20s. No shouting.

## Manifest

Edit `manifest.csv` with stopwatch-measured onset times:
- `quiet_normal`: `nan` (no event expected)
- `quiet_shout`: seconds when shouting starts
- `noisy_normal`: `nan` (no event expected)
- `noisy_shout`: seconds when shouting starts
- `transition`: seconds when ambient noise turns on (NOT shouting)

## Running

    bash process_all.sh
