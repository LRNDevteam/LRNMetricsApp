import React, { useEffect, useState } from 'react';
import { denialWorkflowService } from '../../services/denialWorkflowService';

/**
 * AR follow-up reporting catalog.
 *
 * This replaces the old static "Reports — coming soon" placeholder. Which reports exist and which
 * are live is read from dbo.DenialReportCatalog, so activating RPT-02 later is a data change rather
 * than a UI edit, and a report can be switched off for one lab without a deploy.
 *
 * Status meanings, straight from the catalog table:
 *   Active   — built and available now.
 *   Inactive — specified, not built yet.
 *   Blocked  — cannot be built correctly until its source events exist; the note names the gap
 *              rather than showing a report that would quietly report the wrong thing.
 */

function pick(row, key) {
  if (!row) return undefined;
  if (row[key] !== undefined) return row[key];
  const pascal = key.charAt(0).toUpperCase() + key.slice(1);
  return row[pascal];
}

const STATUS_META = {
  Active: { label: 'Active', className: 'active' },
  Inactive: { label: 'Inactive', className: 'inactive' },
  Blocked: { label: 'Blocked', className: 'blocked' }
};

export default function ReportCatalogPage({ labId, onOpenReport, setMessage }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    if (!labId) return;
    let cancelled = false;
    setLoading(true);
    denialWorkflowService.getReportCatalog(labId)
      .then(data => { if (!cancelled) setItems(data || []); })
      .catch(err => { if (!cancelled) setMessage?.({ type: 'danger', text: err.message || 'Unable to load the report catalog.' }); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [labId, setMessage]);

  const activeCount = items.filter(x => pick(x, 'status') === 'Active').length;

  return <section className="rpt-catalog-page">
    <header className="rpt-head">
      <div>
        <h2>AR Follow-up Reports</h2>
        <p>
          Operational monitoring, analyst productivity, workload, follow-up compliance, escalations,
          outcomes and SLA reporting for the Denial Workflow. {activeCount > 0
            ? `${activeCount} of ${items.length} reports ${activeCount === 1 ? 'is' : 'are'} live.`
            : 'No reports are live for this lab yet.'}
        </p>
      </div>
    </header>

    {loading && <div className="loading-line" />}

    <div className="rpt-catalog-grid">
      {items.map(item => {
        const status = pick(item, 'status') || 'Inactive';
        const meta = STATUS_META[status] || STATUS_META.Inactive;
        const routeKey = pick(item, 'routeKey');
        const isActive = status === 'Active';
        return <article className={`rpt-catalog-card ${meta.className}`} key={pick(item, 'reportCode')}>
          <div className="rpt-catalog-top">
            <span className="rpt-catalog-code">{pick(item, 'reportCode')}</span>
            <span className={`rpt-badge ${meta.className}`}>{meta.label}</span>
          </div>
          <h3>{pick(item, 'reportName')}</h3>
          <p className="rpt-catalog-purpose">{pick(item, 'purpose')}</p>
          <dl className="rpt-catalog-facts">
            <div><dt>Grain</dt><dd>{pick(item, 'grain') || '—'}</dd></div>
            <div><dt>Status</dt><dd>{pick(item, 'statusNote') || '—'}</dd></div>
          </dl>
          <div className="rpt-catalog-actions">
            {isActive && routeKey
              ? <button type="button" className="wl-btn xs teal" onClick={() => onOpenReport?.(routeKey)}>
                  Open report <i className="bi bi-arrow-right-short" />
                </button>
              : <button type="button" className="wl-btn xs" disabled title={status === 'Blocked' ? 'Blocked on missing source data — see the status note.' : 'Not built yet.'}>
                  {status === 'Blocked' ? 'Blocked' : 'Not available'}
                </button>}
          </div>
        </article>;
      })}
    </div>

    {!loading && items.length === 0 && <div className="workflow-placeholder">
      <div className="workflow-placeholder-icon"><i className="bi bi-bar-chart-line" /></div>
      <div>
        <h2>Reports</h2>
        <p>
          The report catalog has not been provisioned for this lab. Until it is, the Denial Dashboard,
          Aging Dashboard and the per-tab Download actions cover current reporting needs.
        </p>
      </div>
    </div>}
  </section>;
}
