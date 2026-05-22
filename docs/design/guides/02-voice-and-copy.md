# 02 · Voice and copy

Locto's voice is **direct, present, calm**. Brevity is a feature; the product is itself quiet, and its words are too.

## Tone

Not chirpy. Not clinical. Not coachy. Like a friend with one thing to say.

| | Do | Don't |
|---|---|---|
| Pace observation | `You held 161 wpm across 22 minutes.` | `Your speech velocity demonstrated strong consistency metrics.` |
| Filler call-out | `"like" is your tell.` | `Filler-word frequency analysis indicates elevated occurrence patterns.` |
| Praise | `Pace was on point.` | `Excellent! Your pace was crushing it!` |

## Person

Always **second person** ("you held", "your tell"). Never first person plural ("we noticed"). Never third person ("the user").

## Casing

- **Sentence case** for almost everything user-facing: state labels (`Too slow`, `Ideal`, `Too fast`), settings titles, body copy, banners.
- **Title Case** is permitted in menu items per macOS HIG (`Open System Settings…`, `About Locto`, `Pause Coaching`).
- **lowercase** for:
  - the wordmark (`locto`)
  - the tagline (`Speak in your sweet spot.`)
  - in-widget mono label (`monologue`, `take a pause`)
- **UPPERCASE + 0.12em tracking** for tabular labels inside the widget (`IDEAL`, `TOO SLOW`, `MONOLOGUE`). Never for body copy.

## Specifics over abstractions

Use the actual number, the actual word, the actual minute count.

- ✅ "You leaned on 'like' 7 times."
- ❌ "Elevated filler frequency detected."

## Praise → observation, never just praise

State what was on point and *why*, then what wasn't. Don't say "great job" without saying what was great.

## Punctuation

| Glyph | Use |
|---|---|
| `·` (middle dot, `U+00B7`) | Separates inline metadata: `Ideal · avg 142` |
| `—` (em dash, `U+2014`) | Asides: `…right in the sweet spot — keep this as your baseline.` |
| `…` (ellipsis, `U+2026`) | One Unicode char, not three dots. `Listening…` |
| `→` (right arrow, `U+2192`) | Link affordance: `Open System Settings →` |
| `!` | Avoid. Exclamation marks raise the voice. |

## Emoji and unicode

**No emoji.** Ever. The few unicode characters above are typography, not iconography.

## Numbers

- Always **tabular figures** (`font-feature-settings: 'tnum'`).
- Show `--` or `-:--` when data is unavailable — never `0` (it implies a real reading of zero).
- Update at 1 Hz, not 60 Hz — number ticking at high frequency looks twitchy.

## Microcopy reference

| Surface | String |
|---|---|
| Tagline | `Speak in your sweet spot.` |
| One-liner | `An ambient AI speech coach for Mac.` |
| Widget · state labels | `Too slow` · `Ideal` · `Too fast` |
| Widget · mono label | `monologue` (active) → `take a pause` (at ≥ 1:30) |
| Widget · idle placeholders | WPM → `---`; monologue → `-:--` |
| Menu · about | `About Locto` |
| Menu · pause / resume | `Pause Coaching` / `Resume Coaching` |
| Menu · permissions | `Check Permissions` |
| Menu · settings | `Settings…` |
| Menu · quit | `Quit Locto` |
| Settings · window title | `Locto Settings` |
| Settings · sections | `Languages` · `Speaking pace` |
| Permission banner | `Locto needs microphone access to listen to your speech. Open System Settings →` |

## Localization

v1 supports the system locale chosen at first launch (up to 2 languages). Translations should preserve:
- Sentence case for labels
- Lowercase for the `monologue` / `take a pause` widget labels (transliterate if there's no lowercase distinction)
- Tabular numbers (digit-only display is locale-stable)
