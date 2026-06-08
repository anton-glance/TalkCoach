// onboarding-shell.jsx — desktop backdrop, menu bar, scaling stage,
// step router, completion state, and the review toolbar / spec annotations.

const { useState: useStateSh, useEffect: useEffectSh, useRef: useRefSh, useCallback: useCbSh } = React;

const STAGE_W = 1440, STAGE_H = 900;
const REVIEW_H = 56;
const STEP_META = [
  { n: 1, key: 'welcome', label: 'Welcome' },
  { n: 2, key: 'setup', label: 'Set up' },
  { n: 3, key: 'menubar', label: 'Menu bar' },
  { n: 4, key: 'widget', label: 'Widget' },
  { n: 5, key: 'ready', label: 'Ready' },
];

/* ───────────────────────── Menu bar ───────────────────────── */
function MenuGlyph({ d, w = 16 }) {
  return <svg width={w} height="14" viewBox="0 0 24 20" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">{d}</svg>;
}
function MenuBar({ showLocto }) {
  return (
    <div style={{
      position: 'absolute', top: 0, left: 0, right: 0, height: 28, zIndex: 5,
      display: 'flex', alignItems: 'center', justifyContent: 'space-between',
      padding: '0 14px',
      background: 'rgba(250,248,242,0.66)', backdropFilter: 'blur(24px) saturate(180%)',
      WebkitBackdropFilter: 'blur(24px) saturate(180%)',
      borderBottom: '0.5px solid rgba(0,0,0,0.10)',
      color: '#1F2937', fontSize: 13,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 18 }}>
        <div style={{ width: 13, height: 13, borderRadius: 4, background: '#1F2937', opacity: 0.85 }} />
        <span style={{ fontWeight: 600 }}>Locto</span>
        <span style={{ opacity: 0.62 }}>File</span>
        <span style={{ opacity: 0.62 }}>Edit</span>
        <span style={{ opacity: 0.62 }}>Window</span>
        <span style={{ opacity: 0.62 }}>Help</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        {/* Locto status item — sits left of the system icons; appears once the explainer reveals it */}
        <span style={{
          width: 18, display: 'inline-flex', justifyContent: 'center',
          opacity: showLocto ? 1 : 0, transition: 'opacity var(--dur-base) var(--ease-out)',
        }}>
          <window.Mark size={16} color="#1F2937" strokeWidth={3} />
        </span>
        {/* battery */}
        <MenuGlyph w={22} d={<><rect x="2" y="6" width="16" height="9" rx="2" /><rect x="4" y="8" width="9" height="5" rx="1" fill="currentColor" stroke="none" /><path d="M20 9v3" /></>} />
        {/* wifi */}
        <MenuGlyph d={<><path d="M2 8.5a14 14 0 0 1 20 0M5.5 12a9 9 0 0 1 13 0M9 15.2a4 4 0 0 1 6 0" /><circle cx="12" cy="18" r="0.6" fill="currentColor" /></>} />
        {/* search */}
        <MenuGlyph d={<><circle cx="10" cy="9" r="6" /><path d="M15 13l5 5" /></>} />
        {/* control center */}
        <MenuGlyph d={<><rect x="3" y="4" width="18" height="12" rx="3" /><circle cx="9" cy="10" r="2.4" fill="currentColor" stroke="none" /></>} />
        <span style={{ fontSize: 12.5, opacity: 0.9, fontWeight: 450 }}>Mon Jun 1&nbsp;&nbsp;9:41</span>
      </div>
    </div>
  );
}

/* ───────────────────────── Desktop dock ───────────────────────── */
function Dock() {
  const tiles = [
    { c: 'linear-gradient(135deg,#fff,#f0ede5)' },
    { c: 'linear-gradient(135deg,#38bdf8,#2563eb)' },
    { c: 'linear-gradient(135deg,#facc15,#f59e0b)' },
    { c: 'linear-gradient(135deg,#34d399,#0F6E56)' },
    { c: 'linear-gradient(135deg,#f472b6,#ef4444)' },
    { c: 'linear-gradient(135deg,#a78bfa,#6d28d9)' },
  ];
  return (
    <div style={{
      position: 'absolute', bottom: 14, left: '50%', transform: 'translateX(-50%)',
      display: 'flex', gap: 10, padding: '7px 9px', zIndex: 3,
      background: 'rgba(255,255,255,0.28)', backdropFilter: 'blur(28px) saturate(160%)',
      WebkitBackdropFilter: 'blur(28px) saturate(160%)',
      border: '0.5px solid rgba(255,255,255,0.4)', borderRadius: 20,
      boxShadow: 'inset 0 1px 0 rgba(255,255,255,0.45), 0 12px 32px rgba(0,0,0,0.16)',
    }}>
      {tiles.map((t, i) => (
        <div key={i} style={{ width: 44, height: 44, borderRadius: 11, background: t.c, boxShadow: '0 2px 6px rgba(0,0,0,0.16)' }} />
      ))}
    </div>
  );
}

/* ───────────────────────── Completed desktop ─────────────────────────
 * After "Start coaching": modal dismissed, widget live, menu icon active. */
function CompletedDesktop({ onReplay }) {
  const [wpm, setWpm] = useStateSh(150);
  const [mono, setMono] = useStateSh(14);
  useEffectSh(() => {
    const id = setInterval(() => setWpm(w => Math.max(138, Math.min(166, Math.round(w + (Math.random() - 0.5) * 10)))), 1400);
    return () => clearInterval(id);
  }, []);
  useEffectSh(() => {
    const id = setInterval(() => setMono(s => (s >= 75 ? 12 : s + 1)), 1000);
    return () => clearInterval(id);
  }, []);
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 40, pointerEvents: 'none' }}>
      <div style={{ position: 'absolute', left: window.WIDGET_DEFAULT.x, top: window.WIDGET_DEFAULT.y, pointerEvents: 'auto' }}>
        <window.LoctoWidget wpm={wpm} idle={false} monologueSeconds={mono} />
      </div>
      <div style={{
        position: 'absolute', left: '50%', bottom: 150, transform: 'translateX(-50%)',
        display: 'flex', alignItems: 'center', gap: 14, pointerEvents: 'auto',
        padding: '12px 18px', borderRadius: 999,
        background: 'rgba(255,255,255,0.86)', backdropFilter: 'blur(20px) saturate(180%)',
        border: '0.5px solid rgba(0,0,0,0.08)', boxShadow: '0 10px 30px rgba(0,0,0,0.12)',
      }}>
        <window.Mark size={18} color="var(--brand)" strokeWidth={3.2} />
        <span style={{ fontSize: 14, color: 'var(--text-primary)', fontWeight: 450 }}>
          Locto is listening whenever you’re on a call.
        </span>
        <span style={{ width: 1, height: 18, background: 'var(--border-strong)' }} />
        <window.TextLink onClick={onReplay}>Replay onboarding</window.TextLink>
      </div>
    </div>
  );
}

/* ───────────────────────── Spec annotations ─────────────────────────
 * Optional pinned notes for the Claude Code handoff. Off by default. */
const ANNOTATIONS = {
  1: [{ top: 150, left: 70, text: 'Chromeless NSPanel · no title bar, no close button. ~520 × 470 pt, centered, fixed.' },
      { top: 600, right: 70, text: 'Single CTA. No back nav from step 1.' }],
  2: [{ top: 120, left: 60, text: 'Flipping the toggle triggers the macOS microphone prompt — a SYSTEM window. Don’t design or build it; the OS provides it.' },
      { top: 560, left: 60, text: 'Language picks persist to SettingsStore on change — not on CTA — so they survive a restart.' },
      { top: 640, right: 60, text: 'Continue stays disabled until mic granted AND a primary language is set.' }],
  3: [{ top: 150, left: 70, text: 'Standard modal window — same size as steps 1 & 2. No screen-recording or Accessibility permission needed.' },
      { top: 600, right: 70, text: 'Screenshot is a drawn illustration of the menu bar + dropdown — not a live screen capture.' }],
  4: [{ top: 150, left: 70, text: 'Modal window. Inside is the live widget component, pinned to ideal (full green), shown at the top-right corner where it appears during a call.' },
      { top: 600, right: 70, text: 'Real behavior: widget auto-appears on call start; draggable; position persists per display.' }],
  5: [{ top: 130, left: 60, text: 'Has a close button (X) — the only step the user can dismiss from.' },
      { top: 250, right: 60, text: '10 calling apps. Line glyphs are placeholders — swap in real app icons at build.' },
      { top: 640, left: 60, text: 'Start coaching → hasCompletedOnboarding = true; flow never runs again; menu-bar icon goes active.' }],
};
function Annotations({ step }) {
  const items = ANNOTATIONS[step] || [];
  return (
    <div style={{ position: 'absolute', inset: 0, zIndex: 150, pointerEvents: 'none' }}>
      {items.map((a, i) => (
        <div key={i} style={{
          position: 'absolute', top: a.top, left: a.left, right: a.right, maxWidth: 230,
          background: 'rgba(17,23,27,0.9)', color: 'rgba(255,255,255,0.92)',
          fontSize: 12, lineHeight: 1.45, fontWeight: 450,
          padding: '9px 12px', borderRadius: 10,
          border: '0.5px solid rgba(157,225,203,0.4)',
          boxShadow: '0 8px 24px rgba(0,0,0,0.3)',
          fontFamily: 'var(--font-mono)', letterSpacing: 0,
        }}>{a.text}</div>
      ))}
    </div>
  );
}

/* ───────────────────────── Review toolbar (outside the scaled stage) ───────────────────────── */
function ReviewBar({ step, setStep, completed, notes, setNotes, onRestart }) {
  const btn = (label, onClick, opts = {}) => (
    <button onClick={onClick} disabled={opts.disabled} style={{
      appearance: 'none', cursor: opts.disabled ? 'default' : 'pointer',
      height: 32, padding: '0 14px', borderRadius: 8,
      background: opts.active ? 'var(--brand)' : 'rgba(255,255,255,0.08)',
      color: opts.disabled ? 'rgba(255,255,255,0.3)' : (opts.active ? '#fff' : 'rgba(255,255,255,0.86)'),
      border: '0.5px solid rgba(255,255,255,0.16)', fontFamily: 'inherit', fontSize: 13, fontWeight: 500,
      display: 'inline-flex', alignItems: 'center', gap: 7,
    }}>{label}</button>
  );
  return (
    <div style={{
      height: REVIEW_H, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
      gap: 16, background: '#15191b', borderTop: '0.5px solid rgba(255,255,255,0.08)', color: '#fff',
    }}>
      {btn('‹ Prev', () => setStep(s => Math.max(1, s - 1)), { disabled: completed || step === 1 })}
      <div style={{ display: 'flex', gap: 6 }}>
        {STEP_META.map(m => {
          const active = !completed && m.n === step;
          return (
            <button key={m.n} onClick={() => setStep(m.n)} title={m.label} style={{
              appearance: 'none', cursor: 'pointer', height: 32, padding: '0 12px', borderRadius: 7,
              background: active ? 'var(--brand)' : 'rgba(255,255,255,0.06)',
              color: active ? '#fff' : 'rgba(255,255,255,0.6)',
              border: '0.5px solid rgba(255,255,255,0.12)', fontFamily: 'inherit', fontSize: 12.5, fontWeight: 500,
            }}>{m.n} · {m.label}</button>
          );
        })}
      </div>
      {btn('Next ›', () => setStep(s => Math.min(5, s + 1)), { disabled: completed || step === 5 })}
      <span style={{ width: 1, height: 24, background: 'rgba(255,255,255,0.14)' }} />
      {btn(notes ? 'Spec notes: on' : 'Spec notes', () => setNotes(n => !n), { active: notes })}
      {btn('Restart', onRestart)}
    </div>
  );
}

/* ───────────────────────── App ───────────────────────── */
const LS_KEY = 'locto.onboarding.v1';
function loadState() {
  try { return JSON.parse(localStorage.getItem(LS_KEY)) || {}; } catch (e) { return {}; }
}

function App() {
  const saved = loadState();
  const [step, setStep] = useStateSh(saved.step || 1);
  const [completed, setCompleted] = useStateSh(saved.completed || false);
  const [notes, setNotes] = useStateSh(false);
  const [scale, setScale] = useStateSh(1);
  const [store, setStore] = useStateSh(saved.store || { micGranted: false, primary: 'English (US)', secondary: '' });

  // Persist (mirrors spec: selections persist on change; flag on completion).
  useEffectSh(() => {
    localStorage.setItem(LS_KEY, JSON.stringify({ step, completed, store }));
  }, [step, completed, store]);

  // Scale the fixed stage to fit the viewport (minus the review bar).
  useEffectSh(() => {
    const fit = () => {
      const availW = window.innerWidth;
      const availH = window.innerHeight - REVIEW_H;
      const s = Math.min(availW / STAGE_W, availH / STAGE_H);
      setScale(s);
      window.__loctoScale = s;
    };
    fit();
    window.addEventListener('resize', fit);
    return () => window.removeEventListener('resize', fit);
  }, []);

  // Keyboard nav (review affordance — bypasses CTA gating).
  useEffectSh(() => {
    const onKey = (e) => {
      if (completed) return;
      if (e.key === 'ArrowRight') setStep(s => Math.min(5, s + 1));
      if (e.key === 'ArrowLeft') setStep(s => Math.max(1, s - 1));
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [completed]);

  const restart = () => { setCompleted(false); setStep(1); setStore({ micGranted: false, primary: 'English (US)', secondary: '' }); };

  const showLoctoIcon = completed || step >= 3;

  let stepEl = null;
  if (!completed) {
    if (step === 1) stepEl = <window.StepWelcome step={1} totalSteps={5} onNext={() => setStep(2)} />;
    else if (step === 2) stepEl = <window.StepSetup step={2} totalSteps={5} store={store} setStore={setStore} onNext={() => setStep(3)} />;
    else if (step === 3) stepEl = <window.StepMenuBar step={3} totalSteps={5} onNext={() => setStep(4)} />;
    else if (step === 4) stepEl = <window.StepWidget step={4} totalSteps={5} onNext={() => setStep(5)} />;
    else if (step === 5) stepEl = <window.StepReady step={5} totalSteps={5} onComplete={() => setCompleted(true)} onClose={() => setCompleted(true)} />;
  }

  return (
    <div style={{ width: '100vw', height: '100vh', display: 'flex', flexDirection: 'column', background: '#0d0f10', overflow: 'hidden' }}>
      <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', overflow: 'hidden' }}>
        <div style={{
          width: STAGE_W, height: STAGE_H, position: 'relative', flexShrink: 0,
          transform: `scale(${scale})`, transformOrigin: 'center center',
          borderRadius: 12, overflow: 'hidden',
          boxShadow: '0 40px 120px rgba(0,0,0,0.5)',
        }}>
          {/* Wallpaper */}
          <div style={{
            position: 'absolute', inset: 0,
            background:
              'radial-gradient(1200px 820px at 16% -8%, rgba(157,225,203,0.34), transparent 58%),' +
              'radial-gradient(1000px 900px at 96% 18%, rgba(232,205,172,0.42), transparent 56%),' +
              'radial-gradient(960px 820px at 62% 112%, rgba(149,190,170,0.34), transparent 60%),' +
              'linear-gradient(150deg, #ECE6D8 0%, #E4DDCD 52%, #DAD5C8 100%)',
          }} />
          <MenuBar showLocto={showLoctoIcon} />
          <Dock />

          {/* Step content */}
          <div key={completed ? 'done' : 'step-' + step} className="locto-fade-in" style={{ position: 'absolute', inset: 0 }}>
            {completed ? <CompletedDesktop onReplay={restart} /> : stepEl}
          </div>

          {notes && !completed && <Annotations step={step} />}
        </div>
      </div>

      <ReviewBar step={step} setStep={setStep} completed={completed} notes={notes} setNotes={setNotes} onRestart={restart} />
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
