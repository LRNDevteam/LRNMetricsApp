import { badgeClass, statusBadgeClass } from '../utils/format';

export function Loading({ text = 'Loading…' }) {
  return (
    <div className="d-flex align-items-center gap-2 text-secondary py-4">
      <div className="spinner-border spinner-border-sm" role="status" />
      <span>{text}</span>
    </div>
  );
}

export function ErrorBox({ message, onRetry }) {
  if (!message) return null;
  return (
    <div className="alert alert-danger d-flex align-items-start gap-2" role="alert">
      <i className="bi bi-exclamation-triangle-fill mt-1" />
      <div className="flex-grow-1">{message}</div>
      {onRetry && <button type="button" className="btn btn-sm btn-outline-danger" onClick={onRetry}>Retry</button>}
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
      {children && <div className="d-flex gap-2 flex-wrap">{children}</div>}
    </div>
  );
}

export function QueueBadge({ label, subLabel, badge }) {
  if (!label) return <span className="text-secondary">—</span>;
  return (
    <span className={`badge ${badgeClass(badge)} arwb-queue-badge`} title={subLabel ? `${label} · ${subLabel}` : label}>
      {label.replace(/ Queue$/, '')}{subLabel ? ` · ${subLabel}` : ''}
    </span>
  );
}

export function StatusBadge({ status }) {
  return <span className={`badge ${statusBadgeClass(status)}`}>{status}</span>;
}
