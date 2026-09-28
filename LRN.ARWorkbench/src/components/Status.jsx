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

export function PageHeader({ title, subtitle, children }) {
  return (
    <div className="arwb-page-header">
      <div>
        <h1 className="h4 mb-1">{title}</h1>
        {subtitle && <div className="text-secondary small">{subtitle}</div>}
      </div>
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
