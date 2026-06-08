// tokens.js
// JS mirror of DesignTokens.swift — the shipping macOS widget's source of truth.
// Values here must match Sources/DesignTokens.swift in the upstream TalkCoach repo.

window.LoctoTokens = (function () {

  // ── Geometry ──────────────────────────────────────────────────────────
  const Layout = {
    size: 144,
    cornerRadius: 32,
    paddingHorizontal: 13,
    paddingVertical: 11,
    spectrumHeight: 16,
    spectrumBarHeight: 2,
    spectrumBarTopInset: 5,
    caretWidth: 8,
    caretHeight: 5,
    caretTopInset: 9,
    fillerRowGap: 5,
    fillerWordColumnWidth: 56,
    fillerColumnGap: 5,
    pillarWidth: 2.5,
    pillarHeight: 9,
    pillarGap: 2.0,
    pillarCornerRadius: 1,
    pillarOpacity: 0.95,
    maxPillars: 10,
    stateRowGap: 4,
    topGapBetweenWPMAndStateRow: 4,
    hoverYOffset: -3,
    hoverScale: 1.025,
    borderWidth: 0.5,
  };

  // ── Pace ──────────────────────────────────────────────────────────────
  const Pace = {
    wpmIdeal: 140,
    wpmMin: 80,
    wpmMax: 240,
    slowThreshold: 115,
    fastThreshold: 175,
  };

  // ── Color stops ──────────────────────────────────────────────────────
  const ColorStops = {
    slowBase:  [86, 135, 197],
    idealBase: [108, 207, 160],
    fastBase:  [216, 98, 90],
    slowDeep:  [29, 68, 118],
    idealDeep: [31, 90, 64],
    fastDeep:  [110, 50, 32],
  };

  const Tint = { restingAlpha: 0.55, hoverAlpha: 0.72 };
  const Border = { restingWhiteOpacity: 0.55, hoverWhiteOpacity: 0.78 };
  const Shadow = {
    outer: '0 8px 28px rgba(0,0,0,0.18)',
    outerHover: '0 14px 42px rgba(0,0,0,0.26)',
  };

  // ── Helpers — match PaceColors.swift ─────────────────────────────────
  const ease = t => Math.pow(t, 1.6);
  const clamp01 = t => Math.min(1, Math.max(0, t));
  const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
  const rgba = (v, a) => `rgba(${Math.round(v[0])}, ${Math.round(v[1])}, ${Math.round(v[2])}, ${a})`;

  function paceColors(wpm) {
    let tintRGB, deepRGB;
    if (wpm <= Pace.wpmIdeal) {
      const t = ease(clamp01((Pace.wpmIdeal - wpm) / (Pace.wpmIdeal - Pace.wpmMin)));
      tintRGB = mix(ColorStops.idealBase, ColorStops.slowBase, t);
      deepRGB = mix(ColorStops.idealDeep, ColorStops.slowDeep, t);
    } else {
      const t = ease(clamp01((wpm - Pace.wpmIdeal) / (Pace.wpmMax - Pace.wpmIdeal)));
      tintRGB = mix(ColorStops.idealBase, ColorStops.fastBase, t);
      deepRGB = mix(ColorStops.idealDeep, ColorStops.fastDeep, t);
    }
    return { tint: tintRGB, deep: deepRGB };
  }

  function zoneForWPM(wpm) {
    if (wpm < Pace.slowThreshold) return 'tooSlow';
    if (wpm > Pace.fastThreshold) return 'tooFast';
    return 'ideal';
  }

  function zoneLabel(zone) {
    // Sentence case per copy spec (overrides Swift enum's all-caps debug strings).
    return { tooSlow: 'Too slow', ideal: 'Ideal', tooFast: 'Too fast' }[zone];
  }

  function spectrumPosition(wpm) {
    return clamp01((wpm - Pace.wpmMin) / (Pace.wpmMax - Pace.wpmMin));
  }

  // ── Monologue colour stages ───────────────────────────────────────────
  // Bottom-zone tint as a function of elapsed seconds.
  //   0 – 60s : green (calm)
  //   60 – 90s : green → gold (warming up)
  //   90 – 120s: gold → coral (urgent)
  //   120s+   : coral (sustained warning)
  const MonoStops = {
    greenBase: [108, 207, 160],
    goldBase:  [220, 175,  80],
    coralBase: [216,  98,  90],
    greenDeep: [31,  90, 64],
    goldDeep:  [110, 84, 25],
    coralDeep: [110, 50, 32],
  };

  function monoColors(seconds) {
    const s = Math.max(0, seconds);
    let tintRGB, deepRGB;
    if (s < 60) {
      tintRGB = MonoStops.greenBase;
      deepRGB = MonoStops.greenDeep;
    } else if (s < 90) {
      const t = (s - 60) / 30;
      tintRGB = mix(MonoStops.greenBase, MonoStops.goldBase, t);
      deepRGB = mix(MonoStops.greenDeep, MonoStops.goldDeep, t);
    } else if (s < 120) {
      const t = (s - 90) / 30;
      tintRGB = mix(MonoStops.goldBase, MonoStops.coralBase, t);
      deepRGB = mix(MonoStops.goldDeep, MonoStops.coralDeep, t);
    } else {
      tintRGB = MonoStops.coralBase;
      deepRGB = MonoStops.coralDeep;
    }
    return { tint: tintRGB, deep: deepRGB };
  }

  return {
    Layout, Pace, ColorStops, Tint, Border, Shadow,
    paceColors, monoColors, zoneForWPM, zoneLabel, spectrumPosition, rgba,
  };
})();
