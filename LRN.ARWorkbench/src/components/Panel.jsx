import Icon from './Icon';

/** The mockup's .kpi-tile: label, big value, optional delta line. */
export function Kpi({ label, value, delta }) {
  return (
    <div className="arwb-panel arwb-kpi-tile">
      <span className="arwb-kpi-accent-bar" />
      <span className="arwb-kpi-label">{label}</span>
      <span className="arwb-kpi-value">{value}</span>
      {delta}
    </div>
  );
}

/** The mockup's .card with a .card-head (icon, h3, .card-sub, .card-head-actions). */
export function Card({ icon, title, sub, action, children, flush, className = '' }) {
  return (
    <div className={`arwb-panel arwb-section ${className}`.trim()}>
      <div className="arwb-panel-head">
        {icon && <Icon name={icon} />}
        <h3>{title}</h3>
        {sub && <span className="arwb-card-sub">{sub}</span>}
        {action && <div className="arwb-panel-head-actions">{action}</div>}
      </div>
      <div className={flush ? '' : 'arwb-panel-pad'}>{children}</div>
    </div>
  );
}

export function GoTo({ onClick, children }) {
  return <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={onClick}>{children} &rarr;</button>;
}
