// Small hand-built charts, the same primitives as the mockup's charts.js (no chart library).

// Teal ramp, light -> dark, for ordinal data such as AR aging buckets.
const RAMP = ['#BFE6E3', '#8FD2CD', '#5CB9B2', '#33998F', '#1C7A72', '#0F6E6A', '#0A4F4C'];

export function sequentialRamp(count) {
  if (count <= 0) return [];
  return Array.from({ length: count }, (_, i) => RAMP[Math.round(i * (RAMP.length - 1) / Math.max(1, count - 1))]);
}

/**
 * Horizontal ranked bar list. items: [{ label, value, display, color, onClick }].
 * A row with onClick is a button (drill-through), otherwise plain text.
 */
export function BarList({ items, empty = 'No data in the current scope.' }) {
  if (!items.length) return <div className="text-secondary small py-2">{empty}</div>;
  const max = Math.max(1, ...items.map((i) => i.value));
  return (
    <div className="arwb-bar-list">
      {items.map((i) => {
        const body = (
          <>
            <span className="arwb-br-label">{i.label}</span>
            <span className="arwb-br-track">
              <span className="arwb-br-fill" style={{ width: `${Math.max(2, (i.value / max) * 100)}%`, background: i.color || 'var(--arwb-accent)' }} />
            </span>
            <span className="arwb-br-val">{i.display ?? i.value}</span>
          </>
        );
        return i.onClick
          ? <button key={i.label} type="button" className="arwb-bar-row arwb-bar-row-btn" title={`${i.label}: ${i.display ?? i.value}`} onClick={i.onClick}>{body}</button>
          : <div key={i.label} className="arwb-bar-row" title={`${i.label}: ${i.display ?? i.value}`}>{body}</div>;
      })}
    </div>
  );
}

/** Donut via SVG stroke-dasharray. segments: [{ label, value, color, display }]. */
export function Donut({ segments, centerLabel, centerSub }) {
  const total = segments.reduce((s, x) => s + Math.max(0, x.value), 0) || 1;
  const R = 15.9155;
  const C = 2 * Math.PI * R;
  let offset = 0;
  return (
    <div className="arwb-donut-wrap">
      <div className="arwb-donut">
        <svg viewBox="0 0 42 42" width="132" height="132" role="img" aria-label={`${centerLabel} ${centerSub || ''}`}>
          <circle cx="21" cy="21" r={R} fill="none" stroke="var(--arwb-border)" strokeWidth="5.4" />
          {segments.map((s) => {
            const dash = (Math.max(0, s.value) / total) * C;
            const el = (
              <circle key={s.label} cx="21" cy="21" r={R} fill="none" stroke={s.color} strokeWidth="5.4"
                strokeDasharray={`${dash} ${C - dash}`} strokeDashoffset={-offset} transform="rotate(-90 21 21)" />
            );
            offset += dash;
            return el;
          })}
        </svg>
        <div className="arwb-donut-center">
          <div className="arwb-donut-label">{centerLabel}</div>
          {centerSub && <div className="text-secondary small">{centerSub}</div>}
        </div>
      </div>
      <div className="d-flex flex-column gap-2 small">
        {segments.map((s) => (
          <span key={s.label}><span className="arwb-legend-sw" style={{ background: s.color }} />{s.label} — <b>{s.display ?? s.value}</b></span>
        ))}
      </div>
    </div>
  );
}
