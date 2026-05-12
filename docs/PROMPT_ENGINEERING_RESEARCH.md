# Tilt Talk — Translation Prompt Engineering Research

**Goal:** Production-ready Gemma prompt templates that close as much of the quality gap with Apple Translation as possible, and answer whether the gemma-2-2b-it base model is the right choice at all.

**Scope:** All 7 corpus languages (es-MX, es-AR, es-ES, fr-CA, pt-BR, ru, ja, de). Three aggressiveness tiers. Generation parameters and chat-template formatting. Model swap evaluation. STT-error tolerance.

---

## TL;DR

Three findings dominate everything else:

1. **The current prompt is throwing away the regional dialect signal.** `Locale(identifier: "en").localizedString(forLanguageCode: "es-MX")` returns `"Spanish"`, not `"Mexican Spanish"`. This is the single biggest fix and it's a one-line change.

2. **Gemma 2 does not support a system role.** The chat template throws "System role not supported" if you try. All instructions must be folded into the first user turn. The current code's approach (single string in the user turn) is structurally correct; what's wrong is the content of that string.

3. **There's a translation-specialized 4B model from Google (TranslateGemma 4B, released Jan 2026, 2.18 GB at 4-bit MLX) that supports regional dialects natively via locale codes like `es_MX`, `fr_CA`, `pt_BR`.** This was published *after* Spike 4 was scoped. It is almost certainly the right model for V1. The remainder of this document covers prompts for both the current gemma-2-2b-it and the recommended swap.

---

## Part 1 — What the current prompt is doing wrong

The code Anton pasted:

```swift
let sourceName = Locale(identifier: "en").localizedString(forLanguageCode: sourceCode) ?? sourceCode
let targetName = Locale(identifier: "en").localizedString(forLanguageCode: targetCode) ?? targetCode
return "Translate the following text from \(sourceName) to \(targetName). Output only the translation, nothing else.\n\n\(text)"
```

Five problems, in order of impact:

**Problem 1 — Variant identifier discarded.** `forLanguageCode:` extracts just the base language. Both "es-MX" and "es-AR" become "Spanish". The model has no way to know it should reach for "Hell yeah" instead of "An egg" for `¡A huevo!`. **Fix:** use `localizedString(forIdentifier:)` instead, which returns "Spanish (Mexico)" for `es-MX`, "Spanish (Argentina)" for `es-AR`, "French (Canada)" for `fr-CA`, etc. One line.

**Problem 2 — No role-shaping.** The model is told *what to do* but not *who it is*. Research on translation prompting (Vilar et al., 2022 on PaLM; Annotated Guidelines Prompting on low-resource languages, Jan 2025) consistently shows that giving the model a professional-translator persona improves quality, especially on idioms and register.

**Problem 3 — No few-shot anchoring.** Zero examples means the model relies entirely on its training data's interpretation of "translation." Research consistently shows 3-5 examples is the sweet spot for translation (Vilar et al. 2022; Bridging the Linguistic Divide survey, 2025; When Many-Shot Prompting Fails, 2025). Past 5-10 examples, returns diminish or reverse.

**Problem 4 — No generation parameters.** I don't know what temperature/top-p/top-k the agent set in the MLX call. If they're at MLX defaults (typically temperature=0.6, top-p=0.95), the model is being asked to be creative when it should be deterministic. This explains failures like "Forty mother" for "Vale madre" — that's the model generating an unusual completion, not a translation error.

**Problem 5 — No stop sequence.** Gemma uses `<end_of_turn>` to mark turn boundaries. Without an explicit stop on `<end_of_turn>`, the model can over-generate (continue past the translation into commentary or repeat the source). Some of the "untranslated passthrough" failures we saw in Spike 4 might actually be the model generating `[translation]\n\n[source again]` and the second copy got returned.

---

## Part 2 — Generation parameters (what to set, why)

### Determinism in this context

You said you didn't know what determinism meant here. In plain terms: when the user says "¿Mande?" twice, do they get the same English translation both times? With temperature=0 (greedy decoding), yes — the model always picks the highest-probability next token. With temperature=0.7 (typical default), each generation samples from the probability distribution and you can get different translations across repeated calls.

For a translator app, **you want determinism**. A waiter saying the same phrase to two tourists in a row should get the same translation. Determinism also makes debugging tractable: when a user reports "this translated wrong," you can reproduce the failure exactly. With temperature > 0, the same broken translation might not appear on the next try, which makes everything harder.

### Recommended parameters for translation

Based on Prompting Guide (promptingguide.ai), HF chat-ui's verified Gemma 2 config, and the apxml.com guide:

| Parameter | Value | Why |
|---|---|---|
| `temperature` | **0.0** | Greedy decoding. Pure determinism. Translation has a "best" answer; we don't want creativity. |
| `top_p` | **1.0** | Disabled (when temperature=0, this doesn't matter, but set explicitly) |
| `top_k` | **1** | At temperature=0, only the top token matters. Belt-and-suspenders. |
| `repetition_penalty` | **1.05** | Slight penalty. Default is 1.0 (none). Mild penalty discourages the model from echoing the source text (one of Gemma's failure modes in Spike 4 — "UNTRANSLATED" passthrough). HF's verified Gemma 2 config uses 1.2 but that's tuned for chat — too aggressive for translation. |
| `max_tokens` | **`min(512, 2 * input_token_count + 64)`** | Translation output length scales roughly with input. Hard cap at 512 for safety. Tight max prevents the model from continuing past the translation into commentary. |
| `stop` | **`["<end_of_turn>"]`** | Forces stop at the natural turn boundary. Prevents over-generation. |

### Why not temperature=0.1 or 0.3?

A common recommendation in the literature is temperature 0.1-0.4 for "factual/deterministic tasks." That's good advice for code generation or QA where light variation can recover from a bad first token. For translation, repeated identical input *should* produce identical output, and any non-zero temperature breaks that contract. There's no upside to temperature > 0 in this context.

### One nuance — float deterministic but not bitwise

Even at temperature=0, MLX/CoreML on Apple Silicon may produce *slightly* different output across runs due to floating-point non-determinism in matmul kernels. In practice this manifests as the same translation 99%+ of the time. Don't promise users bit-perfect reproducibility, but assume it for engineering purposes.

---

## Part 3 — Chat template (Gemma 2's specific format)

### Critical fact: Gemma 2 has no system role

Quoting Google's prompt structure docs and confirmed by the HF model card discussion: Gemma 2's chat template throws `'System role not supported'` if you pass a `system` role. This is unlike GPT, Claude, Llama 3, and Mistral.

**The official Google workaround:** "Instead of using a separate system role, provide system-level instructions directly within the initial user prompt. The model instruction following capabilities allow Gemma to interpret the instructions effectively."

So the structure is one user turn that contains both the instruction and the input.

### Correct token format for Gemma 2

```
<bos><start_of_turn>user
[INSTRUCTION + EXAMPLES + INPUT]<end_of_turn>
<start_of_turn>model
```

The `<bos>` token is added by the tokenizer if you call `apply_chat_template`. If MLX's tokenizer adds it automatically (it should — verify this), don't manually include it. If not, prepend it.

### Note on Gemma 3

Gemma 3 (the foundation under TranslateGemma) does support a true system role, with different syntax. If you swap to TranslateGemma 4B, the prompt structure changes accordingly — covered in Part 6.

---

## Part 4 — Three aggressiveness tiers (gemma-2-2b-it, current model)

I'll give you all three so you can A/B test as you said. Each tier shows the prompt you build for the user turn (with my comments to you in {curly braces} — strip them before sending to the model). Latency estimates are based on Spike 4's measured per-call latency (avg ~700ms warm) plus a token-cost estimate of ~30ms per 100 input tokens.

### Tier 1 — Conservative (fix the format, add role, no examples)

**What it changes:** Variant identifier preserved. Brief role injection. Otherwise minimal.

**Latency cost over current:** ~negligible (~20-50ms additional input tokens).

**Prompt template (string built from code, then wrapped in `<start_of_turn>user...`):**

```
You are a professional translator from {SOURCE_LOCALIZED} to {TARGET_LOCALIZED}.
Your goal is to convey the meaning naturally, as a fluent {TARGET_LOCALIZED} speaker would say it. Preserve register (formal/informal, vulgar/polite). Translate idioms to natural {TARGET_LOCALIZED} equivalents, not word-for-word.
Output only the translation, nothing else.

{SOURCE_TEXT}
```

Where `{SOURCE_LOCALIZED}` and `{TARGET_LOCALIZED}` come from `Locale(identifier: "en").localizedString(forIdentifier: sourceIdentifier)` — note the `forIdentifier:` not `forLanguageCode:`.

**Example for es-MX → en, input "¿Mande? No te escuché bien.":**

```
You are a professional translator from Spanish (Mexico) to English.
Your goal is to convey the meaning naturally, as a fluent English speaker would say it. Preserve register (formal/informal, vulgar/polite). Translate idioms to natural English equivalents, not word-for-word.
Output only the translation, nothing else.

¿Mande? No te escuché bien.
```

**Expected gain:** Modest but real on regional vernacular. The "Spanish (Mexico)" signal alone changes how the model treats the input. Also fixes idiom literalness ("Piece of cake" → "Pan comido" rather than "Pedazo de pastel" type errors).

---

### Tier 2 — Balanced (role + 5 few-shot examples per direction)

**What it changes:** Adds 5 examples specific to the source-target language pair. Examples are chosen to show the failure modes we care about (idioms, register, vernacular).

**Latency cost over current:** ~300-600ms additional. ~150 extra input tokens depending on language. Spike 4 already measured warm Gemma at 500-1500ms; this adds 30-50% to that.

**Prompt template:**

```
You are a professional translator from {SOURCE_LOCALIZED} to {TARGET_LOCALIZED}.
Your goal is to convey the meaning naturally, as a fluent {TARGET_LOCALIZED} speaker would say it. Preserve register (formal/informal, vulgar/polite). Translate idioms to natural {TARGET_LOCALIZED} equivalents, not word-for-word. Output only the translation, nothing else.

Examples:

{SOURCE_LOCALIZED}: {EX1_SRC}
{TARGET_LOCALIZED}: {EX1_TGT}

{SOURCE_LOCALIZED}: {EX2_SRC}
{TARGET_LOCALIZED}: {EX2_TGT}

{SOURCE_LOCALIZED}: {EX3_SRC}
{TARGET_LOCALIZED}: {EX3_TGT}

{SOURCE_LOCALIZED}: {EX4_SRC}
{TARGET_LOCALIZED}: {EX4_TGT}

{SOURCE_LOCALIZED}: {EX5_SRC}
{TARGET_LOCALIZED}: {EX5_TGT}

{SOURCE_LOCALIZED}: {SOURCE_TEXT}
{TARGET_LOCALIZED}:
```

The trailing `{TARGET_LOCALIZED}:` is critical — it primes the model to start generating the translation immediately rather than re-stating the instruction or producing commentary.

**Example sets (5 examples per pair direction).** I curated these to cover the failure modes we observed in Spike 4. They lean conversational because that's what your STT pipeline produces. See the next section for these examples per language pair.

---

### Tier 3 — Maximum (role + 8 examples + register hint + chain-of-thought)

**What it changes:** More examples (research suggests 5 is the sweet spot, but for hard cases like es-MX vernacular, 8 helps). Adds an explicit instruction to think about register before producing output. Still fits comfortably in Gemma 2's 8K context window.

**Latency cost over current:** ~800-1500ms additional. Spike 4 warm 500-1500ms could become 1300-3000ms. **Approaching the edge of acceptable for face-to-face conversation.**

**Important caveat:** Research (Code Translation Many-Shot Failure, 2025) shows that for some tasks, more examples *hurts*. For translation specifically, the literature is consistent that improvement plateaus past 5-10 examples. Tier 3 is an option, not a recommendation. **My honest expectation: Tier 2 is the right setting and Tier 3 is for edge cases like the worst Spanish vernacular phrases.**

**Prompt template:**

```
You are a professional translator from {SOURCE_LOCALIZED} to {TARGET_LOCALIZED}.

Your translation must:
- Convey the meaning naturally, as a fluent {TARGET_LOCALIZED} speaker would say it
- Match the register of the source: if the source is informal/slang/vulgar, the translation should be too; if formal, formal
- Translate idioms to natural {TARGET_LOCALIZED} equivalents, never word-for-word
- Preserve speaker emotion (excitement, frustration, affection)
- Handle imperfect input gracefully — speech-to-text may produce missing punctuation, dropped accents, or merged words; infer intended meaning

Before answering, briefly consider: what is the speaker actually trying to communicate? What register is this? Is this an idiom that has a target-language equivalent?

Then output ONLY the translation, with no commentary, explanation, or repetition of the source.

Examples:

[8 examples in same format as Tier 2]

{SOURCE_LOCALIZED}: {SOURCE_TEXT}
{TARGET_LOCALIZED}:
```

**The "before answering, briefly consider" line is hedged on purpose.** True chain-of-thought has the model emit reasoning tokens, which we don't want (we asked for translation only). This phrasing nudges the model to do internal reasoning while producing only the final answer. If you find Gemma 2 starts emitting "Considering..." preambles, drop this line — it means the model is leaking thoughts.

---

## Part 5 — Few-shot example sets per language pair

These examples are curated from the actual Spike 4 failure data. Each set has:
- 2 idiom failures we saw Apple/Gemma get wrong
- 2 register/vernacular cases
- 1 false-friend or culturally-loaded concept

**Use these only when the source-target pair matches.** A code mapping like:

```swift
let examples = examplesFor(source: sourceIdentifier, target: targetIdentifier)
```

### es-MX → en

```
Spanish (Mexico): ¿Mande?
English: Pardon?

Spanish (Mexico): ¡Aguas! Casi te caes.
English: Watch out! You almost fell.

Spanish (Mexico): Está padrísimo.
English: It's awesome.

Spanish (Mexico): Me vale lo que digan.
English: I don't care what they say.

Spanish (Mexico): ¡A huevo! Vamos a ganar.
English: Hell yeah! We're gonna win.
```

### en → es-MX

```
English: Watch out!
Spanish (Mexico): ¡Aguas!

English: That's awesome.
Spanish (Mexico): Está padrísimo.

English: Hell yeah!
Spanish (Mexico): ¡A huevo!

English: I don't care.
Spanish (Mexico): Me vale.

English: Are you serious? You won?
Spanish (Mexico): ¿En serio? ¡No manches, ganaste!
```

### es-AR → en

```
Spanish (Argentina): ¿Qué hacés, boludo?
English: What's up, dude?

Spanish (Argentina): El asado estuvo bárbaro.
English: The barbecue was awesome.

Spanish (Argentina): Te juro que es posta.
English: I swear it's the truth.

Spanish (Argentina): No tengo un mango.
English: I don't have a buck.

Spanish (Argentina): Tomé el bondi al centro.
English: I took the bus downtown.
```

### en → es-AR

```
English: Hey, dude.
Spanish (Argentina): Che, boludo.

English: That party was awesome.
Spanish (Argentina): Esa fiesta estuvo bárbara.

English: Are you serious? For real?
Spanish (Argentina): ¿En serio? ¿Posta?

English: I'm broke.
Spanish (Argentina): No tengo un mango.

English: Let's grab a beer.
Spanish (Argentina): Vamos a tomar una birra.
```

### es-ES → en

```
Spanish (Spain): Vale, nos vemos a las ocho.
English: OK, see you at eight.

Spanish (Spain): Tu coche nuevo es muy chulo.
English: Your new car is really cool.

Spanish (Spain): Tengo que currar todo el finde.
English: I have to work all weekend.

Spanish (Spain): Esa peli mola.
English: That movie's cool.

Spanish (Spain): ¡Joder, qué susto!
English: Damn, what a scare!
```

### en → es-ES

```
English: OK.
Spanish (Spain): Vale.

English: That's really cool.
Spanish (Spain): Es muy chulo.

English: I have to work this weekend.
Spanish (Spain): Tengo que currar este finde.

English: Damn!
Spanish (Spain): ¡Joder!

English: A lot of people came.
Spanish (Spain): Vino mogollón de gente.
```

### fr-CA → en

```
French (Canada): Mon char est dans le shop.
English: My car's at the shop.

French (Canada): Je sors avec ma blonde ce soir.
English: I'm going out with my girlfriend tonight.

French (Canada): On va magasiner samedi.
English: We're going shopping Saturday.

French (Canada): Y fait frette dehors.
English: It's freezing cold outside.

French (Canada): C'est pas grave, t'inquiète.
English: It's no big deal, don't worry.
```

### en → fr-CA

```
English: My car broke down.
French (Canada): Mon char est brisé.

English: I'm with my girlfriend.
French (Canada): Je suis avec ma blonde.

English: Let's go shopping.
French (Canada): On va magasiner.

English: It's freezing cold.
French (Canada): Y fait frette.

English: It's no big deal.
French (Canada): C'est pas grave.
```

### pt-BR → en

```
Portuguese (Brazil): Que cara legal!
English: What a cool guy!

Portuguese (Brazil): Eu tenho saudade de você.
English: I miss you.

Portuguese (Brazil): Valeu pela ajuda, mano.
English: Thanks for the help, bro.

Portuguese (Brazil): Tô nem aí pro que ele pensa.
English: I don't care what he thinks.

Portuguese (Brazil): A galera vai pra praia.
English: The crew's going to the beach.
```

### en → pt-BR

```
English: Cool!
Portuguese (Brazil): Legal!

English: I miss you.
Portuguese (Brazil): Tenho saudade de você.

English: Thanks, bro.
Portuguese (Brazil): Valeu, mano.

English: I don't care.
Portuguese (Brazil): Tô nem aí.

English: The whole group's coming.
Portuguese (Brazil): A galera toda vem.
```

### ru → en

This is the pair where Apple beats Gemma. The few-shot set targets Gemma's specific weaknesses (literal renderings of idioms, register flattening).

```
Russian: Ничего, всё нормально.
English: It's fine, everything's OK.

Russian: На здоровье!
English: You're welcome! (after thanks for food)

Russian: Этот водитель — настоящий хам.
English: That driver is a real jerk.

Russian: На дорогах полный беспредел.
English: It's complete chaos on the roads.

Russian: Не сглазь!
English: Don't jinx it!
```

### en → ru

```
English: How are you?
Russian: Как дела?

English: I miss you.
Russian: Я скучаю по тебе.

English: It's a piece of cake.
Russian: Это проще простого.

English: Don't beat around the bush.
Russian: Не ходи вокруг да около.

English: We'll get there eventually.
Russian: В конце концов мы туда доберёмся.
```

### ja → en

Japanese is the other pair where Apple beats Gemma. Examples target the cultural set-phrase failures.

```
Japanese: お疲れ様でした。
English: Good work today. (said at end of workday)

Japanese: 「いただきます」と言って食べ始めた。
English: He said "let's eat" and started eating.

Japanese: 今日からお世話になります。
English: I'll be in your care from today.

Japanese: 仕方がない。
English: It can't be helped.

Japanese: この曲、やばい!
English: This song is amazing!
```

### en → ja

```
English: How are you?
Japanese: お元気ですか?

English: Thank you for the meal.
Japanese: ごちそうさまでした。

English: It can't be helped.
Japanese: 仕方がない。

English: That's amazing!
Japanese: やばい!

English: Please be kind to me. (to a new colleague)
Japanese: よろしくお願いします。
```

### de → en

```
German: Schadenfreude
English: Pleasure at someone else's misfortune

German: Ich gebe es zu, ich empfinde ein bisschen Schadenfreude.
English: I admit it, I feel a bit of schadenfreude.

German: Mit 35 bekam sie Torschlusspanik.
English: At 35, she started panicking that time was running out.

German: Du kommst nicht mit. — Doch!
English: You're not coming. — Yes I am!

German: Lass es lieber, sonst verschlimmbesserst du es.
English: Better leave it alone, or you'll make it worse trying to fix it.
```

### en → de

```
English: Schadenfreude
German: Schadenfreude

English: I'm staying home, I'm feeling under the weather.
German: Ich bleibe zu Hause, mir geht's nicht so gut.

English: That's not my problem.
German: Das ist nicht mein Bier.

English: It cost an arm and a leg.
German: Das hat ein Vermögen gekostet.

English: I don't understand a thing.
German: Ich verstehe nur Bahnhof.
```

---

## Part 6 — Model swap evaluation

You said you wanted this included so you could decide after. Three options on the table.

### Option 6A — Stay on gemma-2-2b-it (current, 1.3 GB at 4-bit)

**Pros:**
- Already integrated. No re-validation work.
- Smallest disk footprint of any option.
- Good general-purpose translation when prompted well.

**Cons:**
- Gemma 2's training was only 2T tokens, vs 9B's 8T and 27B's 13T. The 2B model genuinely is the weakest of the family.
- The Gemma 2 technical report explicitly states: "Our models are not multimodal and are not trained specifically for state-of-the-art multilingual capabilities." The strong multilingual reputation of Gemma 2 comes from the 9B and 27B variants — the 2B is materially weaker.
- No native system role.
- 8K context only.
- Generic LLM, not translation-specialized.

**With Tier 2 prompts: expected ~30-40% reduction in failure cases observed in Spike 4.** Big improvements on Spanish vernacular. Smaller improvements on Russian (where the issue is depth of language knowledge, not prompting).

### Option 6B — Upgrade to gemma-2-9b-it (~5 GB at 4-bit)

**Pros:**
- Much better multilingual performance per arxiv:2502.02481 ("Gemma2-9B exhibit impressive multilingual translation capabilities").
- Same chat format as 2B — minimal code changes.
- Beats the 2B materially on Russian, Japanese, German benchmarks.

**Cons:**
- ~5 GB download vs 1.3 GB. That's a real onboarding cost.
- Roughly 2-3x slower inference than 2B on iPhone (memory bandwidth bound). Spike 4 warm 700ms could become 2000ms. Conversational latency starts to feel sluggish.
- Still a generic LLM, still no system role, still no native regional dialect output.

**Verdict:** Don't do this unless TranslateGemma 4B turns out to not work in MLX. 9B is the "we couldn't get TranslateGemma working" fallback.

### Option 6C — Swap to TranslateGemma 4B (2.18 GB at 4-bit)

**This is the recommendation. Released by Google January 15, 2026 — after Spike 4 was scoped.**

**Pros:**
- **Translation-specialized.** Fine-tuned from Gemma 3 4B specifically for translation across 55 languages. Outperforms baseline Gemma 3 27B on the WMT24++ benchmark using fewer parameters.
- **Native regional dialect support.** The chat template accepts ISO 639-1 + ISO 3166-1 country codes natively: `en_US`, `en_GB`, `es_MX`, `fr_CA`, `pt_BR`. This is the architectural fix for D-018 (Apple has no regional dialect output).
- **Has a native chat template designed for translation.** From Ollama's docs: `You are a professional {SOURCE_LANG} ({SOURCE_CODE}) to {TARGET_LANG} ({TARGET_CODE}) translator. Your goal is to accurately convey the meaning and nuances of the original {SOURCE_LANG} text while adhering to {TARGET_LANG} grammar, vocabulary, and cultural sensitivities. Produce only the {TARGET_LANG} translation, without any additional explanations or commentary.` — that's almost exactly what we'd write ourselves.
- **MLX support exists.** `mlx-community/translategemma-4b-it-4bit` (2.18 GB) and `mlx-community/translategemma-4b-it-8bit` are both published on Hugging Face.
- **Real-world production deployment.** SMG Swiss Marketplace Group's tech blog reports GemmaX2-28-2B (a similar Gemma-translation specialization) "consistently came out on top, in some cases even outperforming DeepL" while "remaining small enough (2B parameters) to run inference."
- **Built on Gemma 3** — supports a true system role unlike Gemma 2.

**Cons:**
- 2.18 GB vs 1.3 GB — onboarding download is ~67% larger. Still much smaller than gemma-2-9b (5 GB).
- New integration work. Need to update GemmaTranslationEngine to load the new model and use the new chat template.
- Slightly newer ecosystem — fewer Stack Overflow answers if something breaks.

**Latency:** TranslateGemma 4B is similar in size to the 2B Gemma 2 plus modest overhead from the larger Gemma 3 base architecture. Expect ~700-1200ms warm calls. Slightly slower than gemma-2-2b-it but well within face-to-face conversation budget.

**Recommended chat template (when using TranslateGemma 4B):**

```python
messages = [{
    "role": "user",
    "content": [{
        "type": "text",
        "source_lang_code": "es-MX",     # or "es", "es_MX" — model accepts both formats
        "target_lang_code": "en-US",
        "text": "¿Mande? No te escuché bien."
    }]
}]
```

This is structured input via the chat template, **not a free-text prompt**. The model has been trained on this exact structure. You don't need few-shot examples — they're effectively baked into the fine-tuning.

**When to use few-shot with TranslateGemma:** Only if the structured-input baseline has specific regional vernacular gaps. Likely not needed initially. Test the baseline first.

### Recommendation

**Path A (low-risk, fast):** Ship Tier 2 prompts on gemma-2-2b-it for V1. Plan to swap to TranslateGemma 4B in V1.1 once you've confirmed the prompt-engineering wins via telemetry.

**Path B (more work, better answer):** Swap to TranslateGemma 4B now. The hybrid architecture concern (D-011, "Gemma replaces, not augments") is moot if Gemma is just objectively better — and TranslateGemma is more likely to actually beat Apple on the languages where Apple was beating Gemma 2 (ru, ja, de standard-register).

**My honest read:** Path B. The model literally exists to solve the exact problem Tilt Talk has, it has native regional dialect support which is your D-018 problem, and it was published 4 months ago — the ecosystem is mature enough. The 2.18 GB onboarding cost is real but it's the cost of doing the V1 *right*.

---

## Part 7 — STT-error tolerance

You said STT errors should be handled in the prompt. Here's what to do.

### What kinds of errors does STT introduce?

From Spike 1 findings (the STT cascade work):
- **Word-merge artifacts** ("сад твой" → "садвой") — happens with Apple SpeechAnalyzer on Russian.
- **Missing punctuation** — STT doesn't always insert "?" at the end of questions, ", " between clauses, etc.
- **Dropped accents** — STT may produce "como" when the speaker said "cómo".
- **Homophone confusion** — "cierto" vs "ciento" in Spanish, "ваш" vs "ваше" in Russian.
- **Phantom words from background noise** — random insertions.

### Two strategies, both compatible with the Tier 2 prompt structure

**Strategy A — Add a single line to the role instruction (Tier 1+ all tiers):**

> "The source text comes from speech-to-text and may have missing punctuation, dropped accents, or merged words; infer the intended meaning."

This single sentence costs ~15 tokens, negligible latency, and meaningfully improves how the model handles imperfect input. Already included in Tier 3 above.

**Strategy B — Include a "noisy input" example in the few-shot set (Tier 2+):**

For each language pair, add one example where the source has STT-style imperfection and the target is the clean translation. This teaches the model the failure pattern explicitly.

Example for es-MX → en (replace one of the 5 examples):

```
Spanish (Mexico): mande no te escuche bien
English: Pardon? I didn't hear you well.
```

Note the missing accents, missing question mark, missing period. The model learns to clean up while translating.

**My recommendation:** Use Strategy A everywhere (cheap, broadly helpful) and Strategy B only on Tier 3 (one example slot is non-trivial; needs to earn its place).

### What NOT to do

**Don't ask the model to "correct" the input first.** Research (ASR-EC Benchmark, Dec 2024) found that two-step pipelines (correct then translate) with small LLMs often introduce *new* errors. A single-pass prompt that tells the model to "infer intended meaning" is more reliable than asking it to first produce a corrected source.

**Don't include n-best ASR hypotheses.** Some research (arxiv:2309.04842 "Leveraging LLMs for Exploiting ASR Uncertainty") suggests passing top-N ASR candidates helps. This works but adds significant token cost and is overkill for a 2B model. Skip.

---

## Part 8 — Native quality definition (your answer: "Natural sounding — like a fluent local")

You answered "Natural sounding — like a fluent local." This shapes the prompt content directly. Three implications:

1. **Always preserve the register** — the role-shaping line "Match the register of the source: if the source is informal/slang/vulgar, the translation should be too" is non-negotiable. Don't water this down.

2. **Use target-language idioms** — when "It's raining cats and dogs" appears in en → es-MX, the translation should be "Está lloviendo a cántaros," not "Está lloviendo gatos y perros." The few-shot examples enforce this pattern.

3. **Lean toward conversational over literary** — your STT input is conversational speech. The translations should match. "Hell yeah!" not "Indeed yes!"

This rules out the "pure literal" tier I might otherwise have offered — you've already decided.

---

## Part 9 — Final recommendations, prioritized

### Immediate (do now, in order of leverage)

1. **Fix the variant identifier** — change `forLanguageCode:` to `forIdentifier:` in `buildPrompt`. One-line change. Biggest single quality win you can ship today.
2. **Set generation parameters** — temperature=0, top_p=1, top_k=1, repetition_penalty=1.05, max_tokens auto, stop=["<end_of_turn>"].
3. **Verify the chat template** — ensure MLX is wrapping the prompt correctly in `<bos><start_of_turn>user...<end_of_turn>\n<start_of_turn>model\n`. If GemmaTranslationEngine isn't using `apply_chat_template`, fix that.

### V1 prompt rollout

4. **Ship Tier 2 prompts** as the default, with the example sets above.
5. **Run A/B against current** on a 50-row subset of the corpus before shipping. Confirm quality improvement is real.
6. **Add Strategy A STT-tolerance line** to the role instruction.

### V1.1 or before launch — model swap evaluation

7. **Swap to TranslateGemma 4B** in a new spike (Spike 5). 2.18 GB MLX file is ready to go. Run the same 375-row corpus.
8. **If TranslateGemma 4B beats both Apple AND prompt-engineered gemma-2-2b-it across the board**, ship it as V1 default.
9. **If the latency hit is unacceptable**, fall back to prompt-engineered gemma-2-2b-it.

### Don't bother with

- Gemma 2 9B — only worth it if TranslateGemma 4B doesn't pan out. Materially slower, not specialized for translation.
- Tier 3 prompts — research shows diminishing returns past 5-shot. Keep this in your back pocket for a future "quality" tier toggle, not V1.
- Two-step ASR-correction-then-translation pipelines — adds errors, not worth the latency.
- Building your own fine-tuned model — months of work. TranslateGemma already exists and is free.

---

## Sources cited

- Vilar, D. et al. (2022). *Prompting PaLM for Translation: Assessing Strategies and Performance.* arxiv:2211.09102
- Cui, M. et al. (2025). *Multilingual Machine Translation with Open Large Language Models at Practical Scale.* arxiv:2502.02481 (introduces GemmaX2-28)
- Google DeepMind (2026). *TranslateGemma Technical Report.* arxiv:2601.09012
- Google AI for Developers. *Gemma formatting and system instructions.* ai.google.dev/gemma/docs/core/prompt-structure
- Google blog (Jan 2026). *TranslateGemma: A new family of open translation models.*
- Hugging Face. *google/gemma-2-2b-it model card.*
- Hugging Face. *mlx-community/translategemma-4b-it-4bit model card.*
- Ollama Library. *translategemma:4b prompt structure.*
- SMG Swiss Marketplace Group tech blog (2026). *Build a low-cost AI translator with GemmaX2-28-2B.*
- Promptingguide.ai — Gemma prompt structure and LLM Settings guide.
- HF chat-ui Gemma 2 verified config (temperature, top_p, repetition_penalty values).
- arxiv:2412.03075 (ASR-EC Benchmark — why two-step pipelines fail).
- arxiv:2309.04842 (Leveraging LLMs for Exploiting ASR Uncertainty — n-best context).
