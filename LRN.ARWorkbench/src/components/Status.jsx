import Icon from './Icon';
import { arQueueBadgeClass, fmt, statusBadgeClass } from '../utils/format';

export function Loading({ text = 'Loading…' }) {
  return (
    <div className="arwb-loading" role="status">
      <span className="arwb-spinner" />
      <span>{text}</span>
    </div>
  );
}

export function ErrorBox({ message, onRetry }) {
  if (!message) return null;
  return (
    <div className="arwb-alert" role="alert">
      <Icon name="warn" size={16} />
      <div className="grow">{message}</div>
      {onRetry && <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-danger" onClick={onRetry}>Retry</button>}
    </div>
  );
}

// A dismissible outcome message: { kind: 'good' | 'info' | 'warning', text, details?: string[] }.
// Errors use ErrorBox.
export function Notice({ notice, onClose }) {
  if (!notice?.text) return null;
  return (
    <div className={`arwb-notice arwb-notice-${notice.kind || 'info'}`} role="status">
      <Icon name={notice.kind === 'warning' ? 'warn' : 'check'} size={16} />
      <div className="grow">
        {notice.text}
        {notice.details?.length > 0 && <ul className="arwb-error-list">{notice.details.map((d, i) => <li key={i}>{d}</li>)}</ul>}
      </div>
      {onClose && <button type="button" className="arwb-icon-btn" onClick={onClose} aria-label="Dismiss"><Icon name="close" size={14} /></button>}
    </div>
  );
}

// The page title and subtitle live in the topbar (AppShell, from NAV). This is the row under it:
// an optional page-specific note on the left and the page's actions on the right.
export function PageHeader({ note, children }) {
  if (!note && !children) return null;
  return (
    <div className="arwb-page-header">
      <div className="arwb-hint">{note}</div>
      {children && <div className="arwb-panel-head-actions" style={{ marginLeft: 0 }}>{children}</div>}
    </div>
  );
}

export function Badge({ className = 'arwb-badge-neutral', dot, title, children }) {
  return <span className={`arwb-badge ${className}${dot ? ' arwb-badge-dot' : ''}`} title={title}>{children}</span>;
}

// "Top queue · Sub-queue" (handoff FR-ARQ-02), coloured by the top-level queue as in the mockup.
export function QueueBadge({ queueId, label, subLabel }) {
  if (!label) return <span className="text-muted-ink">—</span>;
  const text = `${label.replace(/ Queue$/, '')}${subLabel ? ` · ${subLabel}` : ''}`;
  return <Badge className={`${arQueueBadgeClass(queueId)} arwb-queue-badge`} title={text}>{text}</Badge>;
}

// nonCollectible: a denial code on the claim is on the Non-Collectible list (HasNonCollectibleDenial).
export function StatusBadge({ status, nonCollectible }) {
  const badge = <Badge className={statusBadgeClass(status)}>{status}</Badge>;
  if (!nonCollectible) return badge;
  return <span className="arwb-status-stack">{badge}<Badge className="arwb-badge-critical" title="Has a non-collectible denial code">Non-Collectible</Badge></span>;
}

export function PriorityText({ priority }) {
  return priority ? <span className={`priority-${priority}`}>{priority}</span> : <span className="text-muted-ink">—</span>;
}

export function TflBadge({ atRisk }) {
  return atRisk ? <Badge className="arwb-badge-critical" dot>At Risk</Badge> : <Badge className="arwb-badge-good">OK</Badge>;
}

export function AgentName({ name, fallback = 'Unassigned' }) {
  if (!name) return <span className="text-muted-ink">{fallback}</span>;
  return <><span className="arwb-avatar-sm">{fmt.initials(name)}</span>{name}</>;
}
