// onboarding-steps.jsx — the five onboarding steps for Locto v1.
// Steps 1, 2, 5 are chromeless centered modals. Steps 3, 4 are full-screen
// dark overlays (the spec's preferred treatment). All copy is DRAFT, in
// Locto's voice — flagged for product-owner review.

const { useState: useStateS, useEffect: useEffectS, useRef: useRefS } = React;

/* Stage geometry — fixed 1440 × 900 macOS screen. */
const MENUBAR_H = 28;
const WIDGET_DEFAULT = { x: 1440 - 16 - 144, y: MENUBAR_H + 16 }; // top-right inset 16

/* ───────────────────────── Modal shell ─────────────────────────
 * Chromeless white sheet, centered. No title bar (per spec).
 * Fixed footprint across every step so the window never resizes between steps.
 * `align` controls vertical placement of content: 'center' for hero-style
 * steps (welcome, ready), 'top' for form/illustration steps. */
function ModalSheet({ children, footer, onClose = null, dim = true, align = 'top' }) {
  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 100,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      background: dim ? 'rgba(31,41,55,0.10)' : 'transparent',
      backdropFilter: dim ? 'blur(1.5px)' : 'none',
    }}>
      <div style={{
        position: 'relative', width: 560, height: 600, maxWidth: '92%',
        background: 'var(--surface)', borderRadius: 22,
        border: '0.5px solid rgba(0,0,0,0.06)',
        boxShadow: '0 32px 80px rgba(20,30,28,0.30), 0 8px 24px rgba(20,30,28,0.14)',
        padding: '44px 48px 30px', boxSizing: 'border-box',
        display: 'flex', flexDirection: 'column',
      }}>
        {onClose && (
          <button onClick={onClose} aria-label="Close" style={{
            position: 'absolute', top: 16, right: 16, width: 28, height: 28,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            appearance: 'none', border: 'none', borderRadius: '50%', cursor: 'pointer',
            background: 'var(--surface-2)', color: 'var(--text-secondary)', zIndex: 2,
          }}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none">
              <path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
            </svg>
          </button>
        )}
        <div style={{
          flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column',
          justifyContent: align === 'center' ? 'center' : 'flex-start',
        }}>
          {children}
        </div>
        {footer && (
          <div style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between',
            marginTop: 24, flexShrink: 0,
          }}>
            {footer}
          </div>
        )}
      </div>
    </div>
  );
}

/* ═══════════════════════════ STEP 1 · Welcome ═══════════════════════════ */
function StepWelcome({ onNext, step, totalSteps }) {
  return (
    <ModalSheet
      align="center"
      footer={<>
        <window.ProgressDots total={totalSteps} current={step} />
        <window.PrimaryButton onClick={onNext}>Get started</window.PrimaryButton>
      </>}
    >
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', textAlign: 'center' }}>
        <window.Lockup markSize={30} />
        <div style={{
          marginTop: 36,
          fontFamily: '"Inter Display", Inter, sans-serif',
          fontSize: 40, fontWeight: 300, letterSpacing: '-1.6px', lineHeight: 1.08,
          color: 'var(--text-primary)',
        }}>
          speak in your<br />sweet spot.
        </div>
        <p style={{
          marginTop: 18, marginBottom: 0, maxWidth: 380,
          fontSize: 15, lineHeight: 1.65, color: 'var(--text-secondary)', textWrap: 'pretty',
        }}>
          Locto is an ambient speech coach that lives at the edge of your screen.
          It watches your pace and nudges you back to your sweet spot — quietly,
          while you talk. Everything runs on your Mac. Nothing is recorded, and
          nothing ever leaves your device.
        </p>
      </div>
    </ModalSheet>
  );
}

/* ═══════════════════════════ STEP 2 · Permissions + Language ═══════════════════════════ */
function StepSetup({ onNext, step, totalSteps, store, setStore }) {
  const [revokeHint, setRevokeHint] = useStateS(false);

  const micGranted = store.micGranted;
  const primary = store.primary;
  const secondary = store.secondary;
  const sameLang = secondary && secondary === primary;
  const canContinue = micGranted && !!primary && !sameLang;

  // Flipping the toggle triggers the macOS microphone prompt (a system window we
  // don't design or build). Here we represent the granted result directly.
  const handleToggle = () => {
    if (micGranted) { setRevokeHint(true); return; } // one-way during onboarding
    setStore(s => ({ ...s, micGranted: true }));
    setRevokeHint(false);
  };

  return (
    <ModalSheet
      footer={<>
        <window.ProgressDots total={totalSteps} current={step} />
        <window.PrimaryButton onClick={onNext} disabled={!canContinue}>Continue</window.PrimaryButton>
      </>}
    >
      <window.Eyebrow>Set up</window.Eyebrow>
      <h2 style={{ margin: '12px 0 0', fontSize: 26, fontWeight: 500, letterSpacing: '-0.6px', color: 'var(--text-primary)' }}>
        Let’s get you set up.
      </h2>
      <p style={{ margin: '6px 0 0', fontSize: 14, color: 'var(--text-secondary)' }}>
        One permission and your languages. Takes about ten seconds.
      </p>

      {/* Permission row */}
      <div style={{ marginTop: 22 }}>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 14,
          padding: '14px 16px', borderRadius: 14,
          background: 'var(--surface-2)', border: '0.5px solid var(--border)',
        }}>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 15, fontWeight: 500, color: 'var(--text-primary)' }}>Microphone</div>
            <div style={{ fontSize: 13, color: 'var(--text-secondary)', lineHeight: 1.45, marginTop: 2 }}>
              To hear your speech during calls. It’s analyzed on your Mac and discarded — never recorded.
            </div>
          </div>
          <window.Toggle on={micGranted} onClick={handleToggle} />
        </div>

        {!micGranted && (
          <div style={{ marginTop: 8, fontSize: 12.5, color: 'var(--text-tertiary)', lineHeight: 1.45 }}>
            macOS will ask you to confirm.
          </div>
        )}
        {revokeHint && micGranted && (
          <div style={{ marginTop: 10 }}>
            <window.InlineMessage tone="neutral">
              Microphone access is on. To turn it off, manage it in System Settings → Privacy.
            </window.InlineMessage>
          </div>
        )}
      </div>

      {/* Language section */}
      <div style={{ marginTop: 22, display: 'flex', gap: 16 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <label style={{ display: 'block', fontSize: 13, fontWeight: 500, color: 'var(--text-primary)', marginBottom: 7 }}>
            Your main speaking language
          </label>
          <window.Dropdown
            value={primary}
            onChange={(v) => setStore(s => ({ ...s, primary: v }))}
          />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <label style={{ display: 'block', fontSize: 13, fontWeight: 500, color: 'var(--text-primary)', marginBottom: 7 }}>
            Optional second language
          </label>
          <window.Dropdown
            value={secondary}
            onChange={(v) => setStore(s => ({ ...s, secondary: v }))}
            noneLabel="None"
          />
        </div>
      </div>
      {sameLang && (
        <div style={{ marginTop: 10 }}>
          <window.InlineMessage>Choose a different language for the second slot.</window.InlineMessage>
        </div>
      )}

      {/* Privacy footer */}
      <p style={{ margin: '20px 0 0', fontSize: 12.5, color: 'var(--text-tertiary)', lineHeight: 1.5 }}>
        All processing happens on your Mac. Locto works fully offline and never sends your audio anywhere.
      </p>
    </ModalSheet>
  );
}

/* Wallpaper used inside the screenshot crops — matches the desktop in the shell. */
const CROP_WALLPAPER =
  'radial-gradient(380px 260px at 14% -10%, rgba(157,225,203,0.40), transparent 60%),' +
  'radial-gradient(320px 280px at 98% 12%, rgba(232,205,172,0.50), transparent 58%),' +
  'linear-gradient(150deg, #ECE6D8 0%, #E4DDCD 54%, #DAD5C8 100%)';

/* A framed "screenshot" crop of part of the macOS screen, drawn (not captured).
 * Reads as a real screen grab: wallpaper, hairline bezel, soft shadow. */
function ScreenCrop({ height, children, caption }) {
  return (
    <figure style={{ margin: 0 }}>
      <div style={{
        position: 'relative', width: '100%', height, borderRadius: 14, overflow: 'hidden',
        border: '0.5px solid rgba(0,0,0,0.14)',
        boxShadow: '0 12px 30px rgba(20,30,28,0.16), inset 0 0 0 0.5px rgba(255,255,255,0.45)',
      }}>
        <div style={{ position: 'absolute', inset: 0, background: CROP_WALLPAPER }} />
        {children}
      </div>
      {caption && (
        <figcaption style={{
          marginTop: 9, textAlign: 'center', fontSize: 12, color: 'var(--text-tertiary)',
          letterSpacing: '0.01em',
        }}>{caption}</figcaption>
      )}
    </figure>
  );
}

/* Small menu-bar status glyphs for the crop. */
function CropGlyph({ d, w = 17 }) {
  return <svg width={w} height="13" viewBox="0 0 24 18" fill="none" stroke="#1F2937" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" style={{ opacity: 0.78 }}>{d}</svg>;
}

/* ═══════════════════════════ STEP 3 · Menu-bar explainer ═══════════════════════════
 * A normal modal window (same size as 1 & 2). Inside: a drawn screenshot of the
 * top-right menu bar with the Locto icon highlighted and its dropdown open.
 * No screen-recording / Accessibility permission required. */
function StepMenuBar({ onNext, step, totalSteps }) {
  return (
    <ModalSheet
      align="center"
      footer={<>
        <window.ProgressDots total={totalSteps} current={step} />
        <window.PrimaryButton onClick={onNext}>Next</window.PrimaryButton>
      </>}
    >
      <window.Eyebrow>Menu bar</window.Eyebrow>
      <h2 style={{ margin: '12px 0 0', fontSize: 26, fontWeight: 500, letterSpacing: '-0.6px', color: 'var(--text-primary)' }}>
        Locto lives up here.
      </h2>
      <p style={{ margin: '6px 0 18px', fontSize: 14, color: 'var(--text-secondary)', lineHeight: 1.5 }}>
        Look for the ring in your menu bar, top-right. Click it any time to pause coaching or open settings.
      </p>

      <ScreenCrop height={190} caption="Your menu bar, top-right of the screen">
        {/* menu bar strip */}
        <div style={{
          position: 'absolute', top: 0, left: 0, right: 0, height: 32,
          display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '0 16px',
          background: 'rgba(247,245,239,0.96)', backdropFilter: 'blur(20px) saturate(180%)',
          WebkitBackdropFilter: 'blur(20px) saturate(180%)',
          borderBottom: '0.5px solid rgba(0,0,0,0.12)', color: '#1F2937', fontSize: 12.5,
        }}>
          {/* left: faux app menus for realism */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 14, opacity: 0.5, fontSize: 12 }}>
            <span style={{ fontWeight: 600, opacity: 0.9 }}>Zoom</span>
            <span>Edit</span>
            <span>Meeting</span>
          </div>
          {/* right: status cluster — Locto sits to the LEFT of the system items, as on a real Mac */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            {/* highlighted Locto status item — the "ring" the copy points to */}
            <span style={{
              position: 'relative', width: 26, height: 26, borderRadius: 8,
              background: 'var(--brand)', display: 'flex', alignItems: 'center', justifyContent: 'center',
              boxShadow: '0 0 0 3px rgba(15,110,86,0.20), 0 0 16px 3px rgba(15,110,86,0.42)',
            }}>
              <window.Mark size={16} color="#fff" strokeWidth={3.6} />
              {/* caret connecting the ring to its dropdown */}
              <span style={{
                position: 'absolute', top: 'calc(100% + 3px)', left: '50%',
                transform: 'translateX(-50%) rotate(45deg)', width: 12, height: 12,
                background: 'rgba(252,250,245,0.98)', borderRadius: 2,
                boxShadow: '-1px -1px 2px rgba(0,0,0,0.04)',
              }} />
              {/* dropdown opened from the icon */}
              <div style={{
                position: 'absolute', top: 'calc(100% + 8px)', left: '50%', transform: 'translateX(-50%)',
                width: 178,
                background: 'rgba(252,250,245,0.98)', backdropFilter: 'blur(20px)',
                borderRadius: 11, border: '0.5px solid rgba(0,0,0,0.10)',
                boxShadow: '0 16px 38px rgba(20,30,28,0.22)', padding: 6,
                fontSize: 12.5, color: 'var(--text-primary)', textAlign: 'left',
              }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 7, padding: '5px 8px 6px' }}>
                  <span style={{ width: 7, height: 7, borderRadius: '50%', background: 'var(--brand)', boxShadow: '0 0 6px rgba(15,110,86,0.5)' }} />
                  <span style={{ fontWeight: 600 }}>Active</span>
                </div>
                <div style={{ height: '0.5px', background: 'rgba(0,0,0,0.10)', margin: '2px 4px' }} />
                {['Pause coaching', 'Settings…'].map((t, i) => (
                  <div key={i} style={{ padding: '5px 8px', borderRadius: 6 }}>{t}</div>
                ))}
                <div style={{ height: '0.5px', background: 'rgba(0,0,0,0.10)', margin: '2px 4px' }} />
                <div style={{ padding: '5px 8px', borderRadius: 6, color: 'var(--text-secondary)' }}>Quit Locto</div>
              </div>
            </span>
            <CropGlyph w={22} d={<><rect x="2" y="6" width="16" height="9" rx="2" /><rect x="4" y="8" width="9" height="5" rx="1" fill="#1F2937" stroke="none" /><path d="M20 9v3" /></>} />
            <CropGlyph d={<><path d="M2 8a14 14 0 0 1 20 0M5.5 11.5a9 9 0 0 1 13 0M9 15a4 4 0 0 1 6 0" /><circle cx="12" cy="17.4" r="0.7" fill="#1F2937" /></>} />
            <span style={{ opacity: 0.86, fontWeight: 450 }}>9:41</span>
          </div>
        </div>
      </ScreenCrop>
    </ModalSheet>
  );
}

/* ═══════════════════════════ STEP 4 · Widget explainer ═══════════════════════════
 * A normal modal window. Inside: a drawn screenshot of the top-right desktop
 * corner with the live widget sitting where it appears during a call. */
function StepWidget({ onNext, step, totalSteps }) {
  const [wpm, setWpm] = useStateS(150);
  const [mono, setMono] = useStateS(14);
  const [posIdx, setPosIdx] = useStateS(0);

  // The widget glides around the screen to show it can live anywhere — not just corners.
  // Coordinates are top-left of the (scaled) widget inside the crop.
  const POSITIONS = [
    { left: 340, top: 40 },   // upper right
    { left: 150, top: 120 },  // lower middle
    { left: 20,  top: 62 },   // mid left
    { left: 250, top: 92 },   // center-right
    { left: 92,  top: 34 },   // upper middle
  ];

  // Gentle pace drift within the ideal band (stays green) — the widget is the real component.
  useEffectS(() => {
    const id = setInterval(() => setWpm(w => {
      const d = (Math.random() - 0.5) * 10;
      return Math.max(138, Math.min(166, Math.round(w + d)));
    }), 1400);
    return () => clearInterval(id);
  }, []);

  // Monologue timer ticks up in real time, so the clock isn't frozen next to a moving WPM.
  useEffectS(() => {
    const id = setInterval(() => setMono(s => (s >= 75 ? 12 : s + 1)), 1000);
    return () => clearInterval(id);
  }, []);

  // Cycle the widget to a new spot.
  useEffectS(() => {
    const id = setInterval(() => setPosIdx(i => (i + 1) % POSITIONS.length), 2000);
    return () => clearInterval(id);
  }, []);

  const pos = POSITIONS[posIdx];

  return (
    <ModalSheet
      align="center"
      footer={<>
        <window.ProgressDots total={totalSteps} current={step} />
        <window.PrimaryButton onClick={onNext}>Next</window.PrimaryButton>
      </>}
    >
      <window.Eyebrow>The widget</window.Eyebrow>
      <h2 style={{ margin: '12px 0 0', fontSize: 26, fontWeight: 500, letterSpacing: '-0.6px', color: 'var(--text-primary)' }}>
        Put it wherever you like.
      </h2>
      <p style={{ margin: '6px 0 18px', fontSize: 14, color: 'var(--text-secondary)', lineHeight: 1.5 }}>
        The tile appears on its own when a call starts — green means you’re in your sweet spot. Drag it anywhere on your screen, and it stays exactly where you leave it.
      </p>

      <ScreenCrop height={246} caption="Drag the widget anywhere on your screen">
        {/* menu bar sliver for context — Locto sits left of the system icons */}
        <div style={{
          position: 'absolute', top: 0, left: 0, right: 0, height: 24,
          background: 'rgba(247,245,239,0.92)', backdropFilter: 'blur(18px) saturate(180%)',
          WebkitBackdropFilter: 'blur(18px) saturate(180%)',
          borderBottom: '0.5px solid rgba(0,0,0,0.10)',
          display: 'flex', alignItems: 'center', justifyContent: 'flex-end', gap: 11, padding: '0 12px',
          color: '#1F2937', fontSize: 11.5,
        }}>
          <window.Mark size={13} color="var(--brand)" strokeWidth={3.2} />
          <CropGlyph w={20} d={<><rect x="2" y="6" width="16" height="9" rx="2" /><rect x="4" y="8" width="9" height="5" rx="1" fill="#1F2937" stroke="none" /><path d="M20 9v3" /></>} />
          <CropGlyph w={15} d={<><path d="M2 8a14 14 0 0 1 20 0M5.5 11.5a9 9 0 0 1 13 0M9 15a4 4 0 0 1 6 0" /><circle cx="12" cy="17.4" r="0.7" fill="#1F2937" /></>} />
          <span style={{ opacity: 0.72 }}>9:41</span>
        </div>

        {/* the real widget — glides around the screen to show it's movable */}
        <div style={{
          position: 'absolute', left: pos.left, top: pos.top,
          transform: 'scale(0.72)', transformOrigin: 'top left',
          transition: 'left 0.95s cubic-bezier(0.4,0,0.2,1), top 0.95s cubic-bezier(0.4,0,0.2,1)',
        }}>
          <window.LoctoWidget wpm={wpm} idle={false} monologueSeconds={mono} />
          {/* drag cursor riding along with the tile */}
          <svg width="22" height="22" viewBox="0 0 24 24" style={{ position: 'absolute', right: 8, bottom: 6, filter: 'drop-shadow(0 1px 2px rgba(0,0,0,0.4))' }}>
            <path d="M5 3l5.5 16 2.2-6.4L19 10 5 3z" fill="#fff" stroke="#1F2937" strokeWidth="1.2" strokeLinejoin="round" />
          </svg>
        </div>
      </ScreenCrop>
    </ModalSheet>
  );
}

/* ═══════════════════════════ STEP 5 · You're set ═══════════════════════════ */

// Minimal Lucide-style line glyphs (generic comm icons — NOT brand logos).
function G({ children }) {
  return <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round">{children}</svg>;
}
const APPS = [
  { name: 'Zoom',     glyph: <G><rect x="2" y="6" width="13" height="12" rx="2" /><path d="M15 10l6-3v10l-6-3" /></G> },
  { name: 'Teams',    glyph: <G><circle cx="9" cy="8" r="3" /><path d="M3 19a6 6 0 0 1 12 0" /><circle cx="18" cy="9" r="2.2" /><path d="M16.5 19a4.5 4.5 0 0 1 5.5-4.3" /></G> },
  { name: 'Meet',     glyph: <G><rect x="3" y="6" width="12" height="12" rx="2" /><path d="M15 10l6-3v10l-6-3" /></G> },
  { name: 'FaceTime', glyph: <G><rect x="2" y="5" width="14" height="14" rx="3" /><path d="M16 10l6-3v10l-6-3" /></G> },
  { name: 'Slack',    glyph: <G><rect x="4" y="4" width="16" height="16" rx="4" /><path d="M9 9h6M9 13h4" /></G> },
  { name: 'Discord',  glyph: <G><path d="M7 7a14 14 0 0 1 10 0M6 17a14 14 0 0 0 12 0" /><circle cx="9" cy="13" r="1.3" /><circle cx="15" cy="13" r="1.3" /><path d="M6 17l-1 3 3-2M18 17l1 3-3-2" /></G> },
  { name: 'Webex',    glyph: <G><circle cx="12" cy="12" r="9" /><circle cx="12" cy="12" r="3.2" /></G> },
  { name: 'Skype',    glyph: <G><circle cx="12" cy="12" r="9" /><path d="M8.5 14.5c1 1.2 5 1.6 6-.2.9-1.7-1.6-2.4-3.2-2.8s-3-1-2.3-2.6c.8-1.7 4.6-1.4 5.6-.3" /></G> },
  { name: 'WhatsApp', glyph: <G><path d="M4 20l1.6-4A8 8 0 1 1 9 18.4L4 20z" /><path d="M9 9c0 3 3 6 6 6 1.2 0 1.2-1.2.5-1.8-.5-.4-1.3.4-2 .1-1.2-.5-2.4-1.7-2.9-2.9-.3-.7.5-1.5.1-2C10.2 7.8 9 7.8 9 9z" /></G> },
  { name: 'Telegram', glyph: <G><path d="M21 5L3 12l5 2 2 5 3-4 5 3 3-13z" /><path d="M8 14l9-6-6 7" /></G> },
];

function AppParade() {
  // Marquee: two copies of the set scroll seamlessly.
  const tile = (app, i) => (
    <div key={i} style={{
      flexShrink: 0, width: 92, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8,
    }}>
      <div style={{
        width: 60, height: 60, borderRadius: 16,
        background: 'var(--surface-2)', border: '0.5px solid var(--border)',
        display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--text-secondary)',
      }}>{app.glyph}</div>
      <div style={{ fontSize: 11.5, color: 'var(--text-tertiary)', fontWeight: 450 }}>{app.name}</div>
    </div>
  );
  return (
    <div style={{ position: 'relative', overflow: 'hidden', width: '100%', marginTop: 4 }}>
      <div className="locto-marquee" style={{ display: 'flex', gap: 6, width: 'max-content' }}>
        {APPS.map(tile)}{APPS.map((a, i) => tile(a, i + 100))}
      </div>
      {/* edge fades */}
      <div style={{ position: 'absolute', top: 0, bottom: 0, left: 0, width: 48, background: 'linear-gradient(90deg, var(--surface), transparent)', pointerEvents: 'none' }} />
      <div style={{ position: 'absolute', top: 0, bottom: 0, right: 0, width: 48, background: 'linear-gradient(270deg, var(--surface), transparent)', pointerEvents: 'none' }} />
    </div>
  );
}

function StepReady({ onComplete, onClose, step, totalSteps }) {
  return (
    <ModalSheet
      align="center"
      onClose={onClose}
      footer={
        <div style={{ display: 'flex', justifyContent: 'flex-end', width: '100%' }}>
          <window.PrimaryButton onClick={onComplete}>Start coaching</window.PrimaryButton>
        </div>
      }
    >
      <div style={{ textAlign: 'center', display: 'flex', flexDirection: 'column', alignItems: 'center' }}>
        <window.Lockup markSize={30} />
        <h2 style={{ margin: '32px 0 0', fontSize: 30, fontWeight: 500, letterSpacing: '-0.8px', color: 'var(--text-primary)' }}>
          You’re all set.
        </h2>
        <p style={{ margin: '8px 0 0', maxWidth: 400, fontSize: 15, lineHeight: 1.6, color: 'var(--text-secondary)', textWrap: 'pretty' }}>
          Open your favorite calling app and start talking. Locto appears on its own — no buttons to press.
        </p>
      </div>
      <div style={{ marginTop: 26 }}>
        <AppParade />
      </div>
    </ModalSheet>
  );
}

Object.assign(window, {
  StepWelcome, StepSetup, StepMenuBar, StepWidget, StepReady,
  MENUBAR_H, WIDGET_DEFAULT,
});
