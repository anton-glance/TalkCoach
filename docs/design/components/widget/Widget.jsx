// Widget.jsx — Locto 144 × 144 floating tile.
//
// Single shared bar in the middle. WPM caret above, monologue caret below.
// Content (text, numbers, bar, carets) is WHITE so it reads cleanly on
// any underlying substrate. The colored state-tint zones provide the contrast.
//
// Hover affects ONLY scale + shadow — the colors stay locked so the visual
// identity doesn't drift when the cursor passes over.
// Idle is MORE translucent than active (the widget steps back when silent).

const { useState: useStateV2 } = React;
const TV2 = window.LoctoTokens;

(function installKeyframesV2() {
  const id = 'locto-widget-keyframes';
  if (document.getElementById(id)) return;
  const style = document.createElement('style');
  style.id = id;
  style.textContent =
    '@keyframes locto-mono-signal-soft   { 0%,100%{opacity:1;} 50%{opacity:0.72;} }' +
    '@keyframes locto-mono-signal-strong { 0%,100%{opacity:1;} 50%{opacity:0.5;}  }';
  document.head.appendChild(style);
})();

function formatMonologueV2(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  const m = Math.floor(s / 60);
  const r = s % 60;
  return m + ':' + String(r).padStart(2, '0');
}
function clamp01V2(x) { return Math.max(0, Math.min(1, x)); }
function monoAnimV2(seconds) {
  if (seconds >= 120) return 'locto-mono-signal-strong 2.5s cubic-bezier(0.42,0,0.58,1) infinite';
  if (seconds >= 90)  return 'locto-mono-signal-soft 2.5s cubic-bezier(0.42,0,0.58,1) infinite';
  return 'none';
}

function WidgetV2({
  wpm = 152,
  idle = false,
  monologueSeconds = 0,
  onPointerDown,
}) {
  const [hovering, setHovering] = useStateV2(false);

  const idleTintRGB = [191, 196, 199];
  const live = TV2.paceColors(wpm);
  const liveMono = TV2.monoColors(monologueSeconds);

  const wpmTintRGB  = idle ? idleTintRGB : live.tint;
  const monoTintRGB = idle ? idleTintRGB : liveMono.tint;

  // Tint alpha is now constant across hover AND substrate — the state colour
  // reads reliably on any background (white, photo, dark window, etc).
  // Idle handled by outer `opacity`, not by changing the tint.
  const tintAlpha   = 0.78;
  const borderAlpha = 0.45;

  const wpmTintColor  = TV2.rgba(wpmTintRGB, tintAlpha);
  const monoTintColor = TV2.rgba(monoTintRGB, tintAlpha);

  // White content — slightly softened so it reads like Apple's system
  // widgets (look at the Calendar widget: not pure white).
  const fg     = 'rgba(255,255,255,0.94)';   // numbers, the main signal
  const fgDim  = 'rgba(255,255,255,0.68)';   // labels
  const fgBar  = 'rgba(255,255,255,0.62)';   // shared bar
  const fgCaret= 'rgba(255,255,255,0.82)';   // pointers

  const paceCaretPct = TV2.spectrumPosition(wpm);
  const monoFillPct  = clamp01V2(monologueSeconds / 90);

  const stateText = idle ? '' : TV2.zoneLabel(TV2.zoneForWPM(wpm));
  const monoLabelText = idle ? '' : (monologueSeconds >= 90 ? 'take a pause' : 'monologue');
  const monoOpacity = idle ? 1 : (0.6 + clamp01V2(monologueSeconds / 90) * 0.4);

  const tintLayer = 'linear-gradient(180deg, ' + wpmTintColor + ' 0%, ' + wpmTintColor + ' 32%, ' + monoTintColor + ' 68%, ' + monoTintColor + ' 100%)';

  // Subtle specular highlight on top edge — same in hover and resting.
  const specularLayer =
    'radial-gradient(140% 60% at 50% -10%, rgba(255,255,255,0.24) 0%, rgba(255,255,255,0) 55%), ' +
    'radial-gradient(120% 50% at 50% 110%, rgba(255,255,255,0.08) 0%, rgba(255,255,255,0) 60%)';

  const bg = specularLayer + ', ' + tintLayer;

  // Shadow stack — hover grows the outer shadows only (lift), colors stay.
  const shadow = hovering
    ? [
        'inset 0 1px 0 rgba(255,255,255,0.55)',
        'inset 0 0 0 0.5px rgba(255,255,255,0.18)',
        'inset 0 -0.5px 0 rgba(0,0,0,0.04)',
        '0 22px 56px rgba(0,0,0,0.28)',
        '0 6px 20px rgba(0,0,0,0.12)',
        '0 1px 3px rgba(0,0,0,0.08)',
      ].join(', ')
    : [
        'inset 0 1px 0 rgba(255,255,255,0.55)',
        'inset 0 0 0 0.5px rgba(255,255,255,0.18)',
        'inset 0 -0.5px 0 rgba(0,0,0,0.04)',
        '0 16px 44px rgba(0,0,0,0.22)',
        '0 4px 14px rgba(0,0,0,0.10)',
        '0 1px 2px rgba(0,0,0,0.06)',
      ].join(', ');

  return (
    <div
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
      onPointerDown={onPointerDown}
      style={{
        width: TV2.Layout.size,
        height: TV2.Layout.size,
        borderRadius: TV2.Layout.cornerRadius,
        padding: '10px 14px',
        boxSizing: 'border-box',
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'space-between',
        position: 'relative',
        background: bg,
        backdropFilter: 'blur(40px) saturate(180%) brightness(1.04)',
        WebkitBackdropFilter: 'blur(40px) saturate(180%) brightness(1.04)',
        border: '0.5px solid rgba(255,255,255,' + borderAlpha + ')',
        boxShadow: shadow,
        // Idle: the entire widget fades to ~50% — calm step-back.
        // Active: fully present. Soft cross-fade either direction.
        opacity: idle ? 0.5 : 1,
        // Hover changes ONLY scale + lift, never colour.
        transform: (!idle && hovering)
          ? 'translateY(' + TV2.Layout.hoverYOffset + 'px) scale(' + TV2.Layout.hoverScale + ')'
          : 'none',
        transition: 'opacity 700ms cubic-bezier(0.42,0,0.58,1), transform 280ms ease-out, box-shadow 280ms ease-out',
        cursor: onPointerDown ? 'grab' : 'default',
        fontFamily: '"Inter Display", Inter, -apple-system, system-ui, sans-serif',
        userSelect: 'none',
        WebkitUserSelect: 'none',
      }}
    >
      {/* TOP HALF · WPM */}
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2 }}>
        <div style={{ display: 'inline-flex', alignItems: 'baseline' }}>
          {!idle && (
            <span aria-hidden="true" style={{
              visibility: 'hidden', marginRight: 1, fontSize: 8, fontWeight: 500,
              letterSpacing: '0.04em', textTransform: 'uppercase', lineHeight: 1, whiteSpace: 'nowrap',
            }}>wpm</span>
          )}
          <span style={{
            fontSize: 36, fontWeight: 300, letterSpacing: '-1.8px', lineHeight: 1,
            color: fg, fontVariantNumeric: 'tabular-nums', fontFeatureSettings: '"tnum"',
          }}>{idle ? '---' : wpm}</span>
          {!idle && (
            <span style={{
              marginLeft: 1, fontSize: 8, fontWeight: 500, letterSpacing: '0.04em',
              textTransform: 'uppercase', color: 'rgba(255,255,255,0.55)', lineHeight: 1, whiteSpace: 'nowrap',
            }}>wpm</span>
          )}
        </div>
        <div style={{
          fontSize: 9, fontWeight: 600, letterSpacing: '0.14em', textTransform: 'uppercase',
          color: fgDim, lineHeight: 1.1,
          visibility: idle ? 'hidden' : 'visible',
        }}>{idle ? 'X' : stateText}</div>
      </div>

      {/* MIDDLE · single shared bar with two carets · all white */}
      <div style={{ position: 'relative', width: '100%', height: 14 }}>
        {!idle && (
          <div style={{
            position: 'absolute', top: 0, left: (paceCaretPct * 100) + '%',
            transform: 'translateX(-50%)', width: 0, height: 0,
            borderLeft: '4px solid transparent', borderRight: '4px solid transparent',
            borderTop: '5px solid ' + fgCaret,
            transition: 'left 600ms cubic-bezier(0.42,0,0.58,1)',
          }} />
        )}
        <div style={{
          position: 'absolute', top: 6, left: 0, right: 0, height: 2,
          borderRadius: 1,
          background: fgBar,
        }} />
        {!idle && (
          <div style={{
            position: 'absolute', top: 9, left: (monoFillPct * 100) + '%',
            transform: 'translateX(-50%)', width: 0, height: 0,
            borderLeft: '4px solid transparent', borderRight: '4px solid transparent',
            borderBottom: '5px solid ' + fgCaret,
            transition: 'left 600ms cubic-bezier(0.42,0,0.58,1)',
          }} />
        )}
      </div>

      {/* BOTTOM HALF · monologue */}
      <div style={{
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2,
        animation: idle ? 'none' : monoAnimV2(monologueSeconds),
        opacity: idle ? 1 : monoOpacity,
      }}>
        {/* Colon-centered time — the `:` is optically lower than the digits
            in most fonts; nudge it up by ~0.09em so it sits at the digit
            optical centre. Both active (M:SS) and idle (-:--) get the fix. */}
        {(() => {
          const text = idle ? '-:--' : formatMonologueV2(monologueSeconds);
          const i = text.indexOf(':');
          const numStyle = {
            fontSize: 36, fontWeight: 300, letterSpacing: '-1.8px', lineHeight: 1,
            color: fg, fontVariantNumeric: 'tabular-nums', fontFeatureSettings: '"tnum"',
          };
          if (i < 0) return <div style={numStyle}>{text}</div>;
          return (
            <div style={numStyle}>
              {text.slice(0, i)}
              <span style={{ display: 'inline-block', transform: 'translateY(-0.09em)' }}>:</span>
              {text.slice(i + 1)}
            </div>
          );
        })()}
        <div style={{
          fontSize: 9,
          fontWeight: (monologueSeconds >= 90 && !idle) ? 700 : 600,
          letterSpacing: '0.14em', textTransform: 'uppercase',
          color: fgDim, lineHeight: 1.1,
          visibility: idle ? 'hidden' : 'visible',
        }}>{idle ? 'X' : monoLabelText}</div>
      </div>
    </div>
  );
}

window.LoctoWidget = WidgetV2;
