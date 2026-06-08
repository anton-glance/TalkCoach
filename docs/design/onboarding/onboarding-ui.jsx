// onboarding-ui.jsx — shared primitives for the Locto onboarding flow.
// All values pulled from the Locto design system (tokens.css).
// Exported to window at the bottom so the steps + shell scripts can use them.

const { useState: useStateUI, useEffect: useEffectUI, useRef: useRefUI } = React;

/* ───────────────────────── Brand mark ─────────────────────────
 * The Locto mark: a single ring with a centered dot. currentColor. */
function Mark({ size = 56, color = 'var(--brand)', strokeWidth = 3 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" style={{ display: 'block', color }} aria-label="Locto">
      <circle cx="32" cy="32" r="22" fill="none" stroke="currentColor" strokeWidth={strokeWidth}></circle>
      <circle cx="32" cy="32" r="5.5" fill="currentColor"></circle>
    </svg>
  );
}

/* Wordmark lockup (mark + "locto") used on the welcome screen. */
function Lockup({ markSize = 40 }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
      <Mark size={markSize} strokeWidth={3.2} />
      <span style={{
        fontFamily: '"Inter Display", Inter, sans-serif',
        fontSize: markSize * 0.92, fontWeight: 500, letterSpacing: '-2px',
        color: 'var(--brand)', lineHeight: 1,
      }}>locto</span>
    </div>
  );
}

/* ───────────────────────── Eyebrow ─────────────────────────
 * Uppercase tabular label with a leading em-dash — "— SET UP". */
function Eyebrow({ children }) {
  return (
    <div style={{
      display: 'flex', alignItems: 'center', gap: 8,
      fontSize: 11, fontWeight: 600, letterSpacing: '0.14em', textTransform: 'uppercase',
      color: 'var(--text-tertiary)', lineHeight: 1,
    }}>
      <span aria-hidden="true" style={{ width: 18, height: 1, background: 'currentColor', opacity: 0.7, flexShrink: 0 }} />
      <span>{children}</span>
    </div>
  );
}

/* ───────────────────────── Progress dots ───────────────────────── */
function ProgressDots({ total = 5, current = 1 }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
      {Array.from({ length: total }, (_, i) => {
        const n = i + 1;
        const active = n === current;
        const done = n < current;
        return (
          <div key={n} style={{
            height: 6,
            width: active ? 20 : 6,
            borderRadius: 999,
            background: active ? 'var(--brand)' : done ? 'var(--teal-200)' : 'var(--border-strong)',
            transition: 'all var(--dur-base) var(--ease-out)',
          }} />
        );
      })}
    </div>
  );
}

/* ───────────────────────── Primary button ───────────────────────── */
function PrimaryButton({ children, onClick, disabled = false, full = false }) {
  const [hover, setHover] = useStateUI(false);
  return (
    <button
      onClick={disabled ? undefined : onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      disabled={disabled}
      style={{
        appearance: 'none', border: 'none', cursor: disabled ? 'not-allowed' : 'pointer',
        width: full ? '100%' : 'auto',
        minWidth: 132, height: 44, padding: '0 22px', borderRadius: 11,
        fontFamily: 'inherit', fontSize: 15, fontWeight: 500, letterSpacing: '-0.1px',
        background: disabled ? 'var(--surface-2)' : (hover ? 'var(--brand-dark)' : 'var(--brand)'),
        color: disabled ? 'var(--text-tertiary)' : '#fff',
        boxShadow: disabled ? 'none' : (hover ? '0 6px 18px rgba(15,110,86,0.26)' : '0 2px 8px rgba(15,110,86,0.18)'),
        transition: 'background var(--dur-fast) var(--ease-out), box-shadow var(--dur-fast) var(--ease-out), transform var(--dur-fast) var(--ease-out)',
        transform: (!disabled && hover) ? 'translateY(-1px)' : 'none',
      }}>
      {children}
    </button>
  );
}

/* Quiet text link with the → affordance. */
function TextLink({ children, onClick }) {
  const [hover, setHover] = useStateUI(false);
  return (
    <button onClick={onClick}
      onMouseEnter={() => setHover(true)} onMouseLeave={() => setHover(false)}
      style={{
        appearance: 'none', background: 'none', border: 'none', padding: 0, cursor: 'pointer',
        fontFamily: 'inherit', fontSize: 13, fontWeight: 500, color: 'var(--brand)',
        textDecoration: hover ? 'underline' : 'none', textUnderlineOffset: 3,
      }}>{children}</button>
  );
}

/* ───────────────────────── Permission toggle ─────────────────────────
 * macOS-style switch. One-way during onboarding (see spec). */
function Toggle({ on, onClick }) {
  return (
    <button onClick={onClick} role="switch" aria-checked={on} style={{
      appearance: 'none', border: 'none', cursor: 'pointer', padding: 0,
      width: 42, height: 26, borderRadius: 999,
      background: on ? 'var(--brand)' : '#D8D5CC',
      position: 'relative', flexShrink: 0,
      transition: 'background var(--dur-base) var(--ease-out)',
      boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.06)',
    }}>
      <span style={{
        position: 'absolute', top: 2, left: on ? 18 : 2,
        width: 22, height: 22, borderRadius: '50%', background: '#fff',
        boxShadow: '0 1px 3px rgba(0,0,0,0.22), 0 0 0 0.5px rgba(0,0,0,0.04)',
        transition: 'left var(--dur-base) var(--ease-out)',
      }} />
    </button>
  );
}

/* ───────────────────────── Locales ─────────────────────────
 * Representative subset of SettingsStore.declaredLocales (~50 in prod). */
const LOCALES = [
  'English (US)', 'English (UK)', 'Spanish (Spain)', 'Spanish (Mexico)',
  'French (France)', 'German', 'Italian', 'Portuguese (Brazil)', 'Portuguese (Portugal)',
  'Dutch', 'Swedish', 'Norwegian', 'Danish', 'Finnish', 'Polish', 'Czech',
  'Russian', 'Ukrainian', 'Turkish', 'Arabic', 'Hebrew', 'Hindi',
  'Japanese', 'Korean', 'Chinese (Simplified)', 'Chinese (Traditional)',
  'Indonesian', 'Vietnamese', 'Thai', 'Greek',
];

/* ───────────────────────── Dropdown ─────────────────────────
 * Custom select styled to the system. `noneLabel` adds a clear/None row at top. */
function Dropdown({ value, onChange, placeholder = 'Select…', noneLabel = null, disabledValues = [] }) {
  const [open, setOpen] = useStateUI(false);
  const ref = useRefUI(null);

  useEffectUI(() => {
    if (!open) return;
    const onDoc = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, [open]);

  const display = value || (noneLabel ? noneLabel : placeholder);
  const isPlaceholder = !value;

  const options = noneLabel ? [{ v: '', label: noneLabel }, ...LOCALES.map(l => ({ v: l, label: l }))]
                            : LOCALES.map(l => ({ v: l, label: l }));

  return (
    <div ref={ref} style={{ position: 'relative', width: '100%' }}>
      <button onClick={() => setOpen(o => !o)} style={{
        appearance: 'none', cursor: 'pointer', width: '100%', height: 42,
        display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
        padding: '0 14px', borderRadius: 999,
        background: 'var(--surface)',
        border: open ? '1px solid var(--brand)' : '1px solid var(--border-strong)',
        boxShadow: open ? '0 0 0 3px rgba(15,110,86,0.12)' : 'none',
        fontFamily: 'inherit', fontSize: 14, fontWeight: 450,
        color: isPlaceholder ? 'var(--text-tertiary)' : 'var(--text-primary)',
        transition: 'border-color var(--dur-fast), box-shadow var(--dur-fast)',
      }}>
        <span style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{display}</span>
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none"
          style={{ color: 'var(--text-tertiary)', transform: open ? 'rotate(180deg)' : 'none', transition: 'transform var(--dur-fast)' }}>
          <path d="M6 9l6 6 6-6" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>

      {open && (
        <div style={{
          position: 'absolute', top: 48, left: 0, right: 0, zIndex: 50,
          maxHeight: 232, overflowY: 'auto',
          background: 'var(--surface)', borderRadius: 14,
          border: '0.5px solid var(--border-strong)',
          boxShadow: '0 12px 36px rgba(0,0,0,0.16), 0 2px 8px rgba(0,0,0,0.08)',
          padding: 6,
        }}>
          {options.map((opt, i) => {
            const selected = opt.v === value;
            const isDisabled = disabledValues.includes(opt.v) && opt.v !== '';
            return (
              <div key={i}
                onClick={() => { if (isDisabled) return; onChange(opt.v); setOpen(false); }}
                style={{
                  display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                  padding: '8px 12px', borderRadius: 8, fontSize: 14,
                  cursor: isDisabled ? 'not-allowed' : 'pointer',
                  color: isDisabled ? 'var(--text-tertiary)' : (opt.v === '' ? 'var(--text-secondary)' : 'var(--text-primary)'),
                  background: selected ? 'var(--brand)' : 'transparent',
                  opacity: isDisabled ? 0.5 : 1,
                }}
                onMouseEnter={(e) => { if (!selected && !isDisabled) e.currentTarget.style.background = 'var(--surface-2)'; }}
                onMouseLeave={(e) => { if (!selected) e.currentTarget.style.background = 'transparent'; }}
              >
                <span style={{ color: selected ? '#fff' : undefined }}>{opt.label}</span>
                {selected && (
                  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" style={{ color: '#fff' }}>
                    <path d="M5 13l4 4L19 7" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
                  </svg>
                )}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

/* ───────────────────────── Inline message ─────────────────────────
 * Warm-coral surface used for permission-denied / validation hints. */
function InlineMessage({ children, tone = 'coral' }) {
  const coral = tone === 'coral';
  return (
    <div style={{
      display: 'flex', alignItems: 'flex-start', gap: 8,
      padding: '9px 12px', borderRadius: 10,
      background: coral ? 'linear-gradient(160deg, #E6AFA2, #DC8E7A)' : 'var(--surface-2)',
      border: coral ? '0.5px solid rgba(92,44,31,0.28)' : '0.5px solid var(--border)',
      color: coral ? 'var(--fast-ink)' : 'var(--text-secondary)',
      fontSize: 13, lineHeight: 1.45, fontWeight: 450,
    }}>
      <span>{children}</span>
    </div>
  );
}

Object.assign(window, {
  Mark, Lockup, Eyebrow, ProgressDots, PrimaryButton, TextLink,
  Toggle, Dropdown, InlineMessage, LOCALES,
});
