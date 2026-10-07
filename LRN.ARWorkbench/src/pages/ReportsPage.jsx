import { useEffect, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router';
import Icon from '../components/Icon';
import { Card } from '../components/Panel';
import { ErrorBox, Loading, PageHeader } from '../components/Status';
import { canOpen } from '../config/navigation';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

const FORMATTERS = {
  money: fmt.money,
  count: fmt.count,
  decimal: (v) => (v === null || v === undefined ? '—' : Number(v).toFixed(1)),
  pct: fmt.pct,
  date: fmt.date,
  text: (v) => (v === null || v === undefined || v === '' ? '—' : v)
};

/**
 * T073 / T074 / T075 Reports (mockup App.views.reports): the AR Collections Progress Summary as
 * the featured card, the summary and event reports under it, and where each of the Denial
 * Workflow's RPT-01..09 lives now. Every report comes from /reports/{id} as one table (columns
 * with a format, rows with a level and a total flag), already limited to the caller's scope;
 * Export downloads the same table as Excel. The open report and its date range are in the URL.
 */
export default function ReportsPage() {
  const { labId, lab, user } = useWorkbench();
  const [params, setParams] = useSearchParams();
  const reportId = params.get('report') || '';
  const from = params.get('from') || '';
  const to = params.get('to') || '';
  const [catalog, setCatalog] = useState(null);
  const [report, setReport] = useState(null);
  const [error, setError] = useState('');
  const [reportError, setReportError] = useState('');
  const [loading, setLoading] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [reload, setReload] = useState(0);
  const outputRef = useRef(null);

  useEffect(() => {
    setError('');
    arWorkbenchService.reports(labId).then(setCatalog).catch((e) => setError(e.message));
  }, [labId]);

  useEffect(() => {
    if (!reportId) { setReport(null); return undefined; }
    const controller = new AbortController();
    setLoading(true);
    setReportError('');
    setReport(null);
    arWorkbenchService.report(labId, reportId, { from, to }, controller.signal)
      .then((r) => {
        setReport(r);
        requestAnimationFrame(() => outputRef.current?.scrollIntoView({ behavior: 'smooth', block: 'nearest' }));
      })
      .catch((e) => { if (e.name !== 'AbortError') setReportError(e.message); })
      .finally(() => setLoading(false));
    return () => controller.abort();
  }, [labId, reportId, from, to, reload]);

  if (error) return <ErrorBox message={error} />;
  if (!catalog) return <Loading />;

  const open = (id) => {
    if (id === reportId) setReload((n) => n + 1);
    else setParams({ report: id });
  };
  const setRange = (next) => setParams({ report: reportId, ...(next.from ? { from: next.from } : {}), ...(next.to ? { to: next.to } : {}) });
  const featured = catalog.reports.filter((r) => r.featured);
  const others = catalog.reports.filter((r) => !r.featured);
  const info = catalog.reports.find((r) => r.id === reportId);

  async function exportReport() {
    setExporting(true);
    try { await arWorkbenchService.reportExport(labId, report.id, { from, to }, report.title); } catch (e) { setReportError(e.message); } finally { setExporting(false); }
  }

  return (
    <>
      <PageHeader note={lab?.labName} />

      {featured.map((r) => (
        <div key={r.id} className="arwb-panel arwb-panel-pad arwb-section arwb-report-card arwb-report-featured">
          <div className="arwb-report-card-head"><h3>{r.title}</h3><Icon name="trend" /></div>
          <div className="arwb-hint">{r.description}</div>
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={() => open(r.id)}>View Report</button>
        </div>
      ))}

      <div className="arwb-grid-2 arwb-section">
        {others.map((r) => (
          <div key={r.id} className="arwb-panel arwb-panel-pad arwb-report-card">
            <div className="arwb-report-card-head">
              <h3>{r.title}{r.code && <span className="arwb-badge arwb-badge-neutral arwb-report-code">{r.code}</span>}</h3>
              <Icon name="filetext" />
            </div>
            <div className="arwb-hint">{r.description}</div>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={() => open(r.id)}>View Report</button>
          </div>
        ))}
      </div>

      <div ref={outputRef}>
        {loading && <Loading />}
        {reportError && <ErrorBox message={reportError} onRetry={() => setReload((n) => n + 1)} />}
        {report && (
          <Card title={report.code ? `${report.code} · ${report.title}` : report.title}
            sub={[report.from && `${fmt.date(report.from)} – ${fmt.date(report.to)}`, report.dataRefreshedOn && `as of ${fmt.date(report.dataRefreshedOn)}`].filter(Boolean).join(' · ') || undefined}
            flush
            action={(
              <>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={exportReport} disabled={exporting}>
                  <Icon name="doc" size={15} /> {exporting ? 'Exporting…' : 'Export'}
                </button>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => setParams({})} aria-label="Close report">×</button>
              </>
            )}>
            {info?.hasDateRange && <RangePicker from={from || report.from?.slice(0, 10)} to={to || report.to?.slice(0, 10)} onApply={setRange} />}
            <ReportTable report={report} />
            {(report.note || report.insights.length > 0) && (
              <div className="arwb-panel-pad">
                {report.note && <div className="arwb-section-note">{report.note}</div>}
                {report.insights.length > 0 && (
                  <div className="arwb-report-insights">
                    <h3>Insights</h3>
                    <ul>{report.insights.map((i) => <li key={i}>{i}</li>)}</ul>
                  </div>
                )}
              </div>
            )}
          </Card>
        )}
      </div>

      {catalog.rpt.length > 0 && (
        <Card icon="layers" title="AR Follow-up Reports (RPT-01 – RPT-09)" sub="where each report of the AR Reporting Requirements lives in the AR Workbench" flush>
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead><tr><th scope="col">Report</th><th scope="col">Name</th><th scope="col">In the AR Workbench</th><th scope="col" className="num">Open</th></tr></thead>
              <tbody>
                {catalog.rpt.map((r) => {
                  const screenOk = r.route && (!r.navId || canOpen(user, r.navId));
                  return (
                    <tr key={r.code}>
                      <td className="mono">{r.code}</td>
                      <td>{r.name}</td>
                      <td className="wrap arwb-hint">{r.source}</td>
                      <td className="num">
                        {r.reportId
                          ? <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => open(r.reportId)}>View</button>
                          : screenOk ? <Link className="arwb-btn arwb-btn-sm" to={r.route}>Open</Link> : <span className="arwb-hint">—</span>}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>
      )}
    </>
  );
}

function RangePicker({ from, to, onApply }) {
  const [f, setF] = useState(from || '');
  const [t, setT] = useState(to || '');
  useEffect(() => { setF(from || ''); setT(to || ''); }, [from, to]);
  return (
    <form className="arwb-filters arwb-panel-pad arwb-report-range" onSubmit={(e) => { e.preventDefault(); onApply({ from: f, to: t }); }}>
      <div>
        <label htmlFor="rpt-from">From</label>
        <input id="rpt-from" type="date" className="arwb-input" value={f} max={t || undefined} onChange={(e) => setF(e.target.value)} />
      </div>
      <div>
        <label htmlFor="rpt-to">To</label>
        <input id="rpt-to" type="date" className="arwb-input" value={t} min={f || undefined} onChange={(e) => setT(e.target.value)} />
      </div>
      <button type="submit" className="arwb-btn arwb-btn-sm arwb-btn-primary">Apply</button>
      <span className="arwb-hint">Up to 366 days. Default: the last 30 days.</span>
    </form>
  );
}

function ReportTable({ report }) {
  if (!report.rows.length) return <div className="arwb-empty-state">No data in the current scope{report.from ? ' for this period' : ''}.</div>;
  return (
    <div className="arwb-table-wrap">
      <table className="arwb-data-table arwb-report-table">
        <thead>
          <tr>
            {report.columns.map((c, i) => <th key={c.key} scope="col" className={i > 0 && !['text', 'date'].includes(c.format) ? 'num' : undefined}>{c.label}</th>)}
          </tr>
        </thead>
        <tbody>
          {report.rows.map((row, ri) => (
            <tr key={ri} className={row.isTotal ? 'arwb-report-total' : undefined}>
              {report.columns.map((c, i) => {
                const value = row.values[i];
                const numeric = i > 0 && !['text', 'date'].includes(c.format);
                const cls = [numeric ? 'num mono' : 'wrap', i === 0 && row.level > 0 ? 'arwb-report-indent' : ''].join(' ').trim();
                return <td key={c.key} className={cls}>{(FORMATTERS[c.format] || FORMATTERS.text)(value)}</td>;
              })}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
