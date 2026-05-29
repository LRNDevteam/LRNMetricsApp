import React, { useMemo, useState } from 'react';
import { money } from '../utils/formatters';

const pivotConfig = {
  payer: { label: 'By Payer', title: 'AR Outstanding by Payer', column: 'Payer', key: 'byPayer' },
  classification: { label: 'By Classification', title: 'AR Outstanding by Denial Classification', column: 'Denial Classification', key: 'byClassification' },
  action: { label: 'By Action', title: 'AR Outstanding by Action / Task', column: 'Action / Task', key: 'byAction' }
};

const bucketClasses = ['h0', 'h30', 'h60', 'h90', 'h120'];
const priorityMap = {
  critical: { label: '!', cls: 'pc' },
  high: { label: 'H', cls: 'ph' },
  medium: { label: 'M', cls: 'pm' },
  low: { label: 'L', cls: 'pl' }
};

function compactMoney(value) {
  const n = Number(value || 0);
  if (Math.abs(n) >= 1000000) return `$${(n / 1000000).toFixed(1)}M`;
  if (Math.abs(n) >= 1000) return `$${(n / 1000).toFixed(1)}K`;
  return money(n);
}

function compactCount(value) {
  const n = Number(value || 0);
  if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`;
  if (n >= 1000) return `${Math.round(n / 1000)}K`;
  return n.toLocaleString();
}

function getBucket(row, key) {
  return (row.buckets || []).find(x => x.key === key) || { key, amount: 0, claimCount: 0, slaBreaches: 0 };
}

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

function excelCell(value, type = 'String', style = '') {
  const styleAttr = style ? ` ss:StyleID="${style}"` : '';
  return `<Cell${styleAttr}><Data ss:Type="${type}">${escapeHtml(value)}</Data></Cell>`;
}

function agingExportBucketLabel(bucket, index) {
  const map = {
    d0: '0 - 30 Days',
    d30: '31 - 60 Days',
    d60: '61 - 90 Days',
    d90: '91 - 120 Days',
    d120: '120 Days'
  };
  return map[bucket?.key] || bucket?.label || ['0 - 30 Days', '31 - 60 Days', '61 - 90 Days', '91 - 120 Days', '120 Days'][index] || '';
}

function exportAgingWorkbook(data, buckets) {
  const sheets = [
    ['By Payer', 'AR Outstanding by Payer', 'Payer', data.byPayer || []],
    ['By Classification', 'AR Outstanding by Denial Classification', 'Denial Classification', data.byClassification || []],
    ['By Action Task', 'AR Outstanding by Action / Task', 'Action / Task', data.byAction || []]
  ];
  const exportBuckets = (buckets || []).slice(0, 5);
  const moneyValue = v => Number(Number(v || 0).toFixed(2));
  const sheetXml = sheets.map(([name, title, firstColumn, rows]) => {
    const body = (rows || []).map(row => {
      const bucketCells = exportBuckets.flatMap(b => {
          const cell = getBucket(row, b.key);
        return [
          excelCell(Number(cell.claimCount || 0), 'Number', 'NumberCell'),
          excelCell(moneyValue(cell.amount), 'Number', 'MoneyCell')
        ];
      }).join('');
      return `<Row ss:Height="21">${excelCell(row.name || '', 'String', 'TextCell')}${excelCell(Number(row.priorityScore || 0), 'Number', 'NumberCell')}${bucketCells}${excelCell(Number(row.totalClaims || 0), 'Number', 'NumberCell')}${excelCell(moneyValue(row.totalAmount), 'Number', 'MoneyCell')}${excelCell(Number(row.slaBreaches || 0), 'Number', 'NumberCell')}</Row>`;
    }).join('');
    const bucketHeader = exportBuckets.map((b, i) => `<Cell ss:MergeAcross="1" ss:StyleID="HeaderTop"><Data ss:Type="String">${escapeHtml(agingExportBucketLabel(b, i))}</Data></Cell>`).join('');
    return `<Worksheet ss:Name="${escapeHtml(name)}">
      <Table>
        <Column ss:Width="240"/>
        <Column ss:Width="78"/>
        <Column ss:Width="82"/><Column ss:Width="112"/>
        <Column ss:Width="82"/><Column ss:Width="112"/>
        <Column ss:Width="82"/><Column ss:Width="112"/>
        <Column ss:Width="82"/><Column ss:Width="112"/>
        <Column ss:Width="82"/><Column ss:Width="112"/>
        <Column ss:Width="82"/><Column ss:Width="112"/>
        <Column ss:Width="96"/>
        <Row ss:Height="28"><Cell ss:MergeAcross="14" ss:StyleID="Title"><Data ss:Type="String">${escapeHtml(`${title} / Aging Matrix`)}</Data></Cell></Row>
        <Row ss:Height="12"/>
        <Row ss:Height="24">${excelCell(firstColumn, 'String', 'HeaderTop')}${excelCell('Priority', 'String', 'HeaderTop')}${bucketHeader}<Cell ss:MergeAcross="1" ss:StyleID="HeaderTop"><Data ss:Type="String">Total</Data></Cell>${excelCell('SLA Breach', 'String', 'HeaderTop')}</Row>
        <Row ss:Height="24">${excelCell('', 'String', 'HeaderSub')}${excelCell('', 'String', 'HeaderSub')}${exportBuckets.map(() => `${excelCell('Claim Count', 'String', 'HeaderSub')}${excelCell('Billed Amount', 'String', 'HeaderSub')}`).join('')}${excelCell('Claim Count', 'String', 'HeaderSub')}${excelCell('Billed Amount', 'String', 'HeaderSub')}${excelCell('', 'String', 'HeaderSub')}</Row>
        ${body}
      </Table>
      <WorksheetOptions xmlns="urn:schemas-microsoft-com:office:excel"><FreezePanes/><FrozenNoSplit/><SplitHorizontal>4</SplitHorizontal/><TopRowBottomPane>4</TopRowBottomPane><ActivePane>2</ActivePane></WorksheetOptions>
    </Worksheet>`;
  }).join('');
  const workbook = `<?xml version="1.0" encoding="UTF-8"?>
<?mso-application progid="Excel.Sheet"?>
<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"
 xmlns:o="urn:schemas-microsoft-com:office:office"
 xmlns:x="urn:schemas-microsoft-com:office:excel"
 xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">
 <Styles>
  <Style ss:ID="Default" ss:Name="Normal"><Alignment ss:Vertical="Center"/><Font ss:FontName="Calibri" ss:Size="11"/></Style>
  <Style ss:ID="Title"><Font ss:FontName="Calibri" ss:Size="15" ss:Bold="1" ss:Color="#1F2937"/><Alignment ss:Vertical="Center"/><Interior ss:Color="#FFFFFF" ss:Pattern="Solid"/></Style>
  <Style ss:ID="HeaderTop"><Font ss:FontName="Calibri" ss:Size="10" ss:Bold="1" ss:Color="#FFFFFF"/><Alignment ss:Horizontal="Center" ss:Vertical="Center" ss:WrapText="1"/><Interior ss:Color="#2F5597" ss:Pattern="Solid"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D9E2F3"/><Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#D9E2F3"/></Borders></Style>
  <Style ss:ID="HeaderSub"><Font ss:FontName="Calibri" ss:Size="10" ss:Bold="1" ss:Color="#1F2937"/><Alignment ss:Horizontal="Center" ss:Vertical="Center" ss:WrapText="1"/><Interior ss:Color="#D9EAF7" ss:Pattern="Solid"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#B4C6E7"/><Border ss:Position="Left" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#B4C6E7"/></Borders></Style>
  <Style ss:ID="TextCell"><Alignment ss:Vertical="Center"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#E5E7EB"/></Borders></Style>
  <Style ss:ID="NumberCell"><Alignment ss:Horizontal="Center" ss:Vertical="Center"/><NumberFormat ss:Format="0"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#E5E7EB"/></Borders></Style>
  <Style ss:ID="MoneyCell"><Alignment ss:Horizontal="Right" ss:Vertical="Center"/><NumberFormat ss:Format="$#,##0.00"/><Borders><Border ss:Position="Bottom" ss:LineStyle="Continuous" ss:Weight="1" ss:Color="#E5E7EB"/></Borders></Style>
 </Styles>
 ${sheetXml}</Workbook>`;
  const blob = new Blob([workbook], { type: 'application/vnd.ms-excel;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `AgingDashboard_${new Date().toISOString().slice(0, 10)}.xls`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

export default function AgingDashboardPage({ data = {}, filter = {}, setFilterValue, clearFilter, reviewers = [], options = {}, onCellClick }) {
  const [pivot, setPivot] = useState('payer');
  const [period, setPeriodState] = useState('');
  const config = pivotConfig[pivot];
  const exportRows = data[config.key] || [];
  const rows = exportRows.slice(0, 10);
  const buckets = data.buckets || [];

  const totals = useMemo(() => ({
    amount: Number(data.totalAmount || 0),
    claims: Number(data.totalClaims || 0),
    payers: Number(data.totalPayers || 0),
    breaches: Number(data.totalSlaBreaches || 0)
  }), [data]);

  function setPeriod(value) {
    setPeriodState(value);
    const today = new Date();
    const yyyyMmDd = d => d.toISOString().slice(0, 10);
    const startOfMonth = new Date(today.getFullYear(), today.getMonth(), 1);
    const startOfLastMonth = new Date(today.getFullYear(), today.getMonth() - 1, 1);
    const endOfLastMonth = new Date(today.getFullYear(), today.getMonth(), 0);
    const quarterStartMonth = Math.floor(today.getMonth() / 3) * 3;
    const startOfQuarter = new Date(today.getFullYear(), quarterStartMonth, 1);

    if (value === 'current') {
      setFilterValue?.('fromDate', yyyyMmDd(startOfMonth));
      setFilterValue?.('toDate', '');
    } else if (value === 'last') {
      setFilterValue?.('fromDate', yyyyMmDd(startOfLastMonth));
      setFilterValue?.('toDate', yyyyMmDd(endOfLastMonth));
    } else if (value === 'quarter') {
      setFilterValue?.('fromDate', yyyyMmDd(startOfQuarter));
      setFilterValue?.('toDate', '');
    } else if (value !== 'custom') {
      setFilterValue?.('fromDate', '');
      setFilterValue?.('toDate', '');
    }
  }

  function setCustomDate(key, value) {
    setPeriodState('custom');
    setFilterValue?.(key, value);
  }

  const reviewerOptions = (reviewers || []).map(r => ({ value: r.userName || r.UserName || '', label: r.displayName || r.DisplayName || r.userName || r.UserName || '' })).filter(x => x.value);
  const panelOptions = options?.panelNames || [];
  const periodValue = period || (filter.fromDate || filter.toDate ? 'custom' : '');

  return <div className="aging-dashboard">
    <div className="aging-kpi-strip">
      <AgingKpi tone="all" label="Total Outstanding" amount={totals.amount} count={`${compactCount(totals.claims)} claims / ${compactCount(totals.payers)} payers`} delta={`${compactCount(totals.breaches)} SLA breach`} />
      {buckets.map((b, i) => <AgingKpi key={b.key || i} tone={b.key || 'all'} label={b.label} amount={b.amount} count={`${compactCount(b.claimCount)} claims`} delta={Number(b.slaBreaches || 0) > 0 ? `${compactCount(b.slaBreaches)} SLA breach` : 'Within range'} ok={!Number(b.slaBreaches || 0)} />)}
    </div>

    <div className="aging-toolbar">
      <div className="aging-toggle">
        {Object.entries(pivotConfig).map(([key, item]) => <button key={key} type="button" className={pivot === key ? 'active' : ''} onClick={() => setPivot(key)}>{item.label}</button>)}
      </div>
      <div className="aging-toolbar-filters">
        <label><i className="bi bi-calendar3" /><select value={periodValue} onChange={e => setPeriod(e.target.value)}><option value="">All Date of Service</option><option value="current">Current month</option><option value="last">Last month</option><option value="quarter">Current quarter</option><option value="custom">Custom range</option></select></label>
        {periodValue === 'custom' && <>
          <label className="aging-date-label"><span>Start</span><input type="date" value={filter.fromDate || ''} onChange={e => setCustomDate('fromDate', e.target.value)} /></label>
          <label className="aging-date-label"><span>End</span><input type="date" value={filter.toDate || ''} onChange={e => setCustomDate('toDate', e.target.value)} /></label>
        </>}
        <label><i className="bi bi-person" /><select value={filter.reviewer || ''} onChange={e => setFilterValue?.('reviewer', e.target.value)}><option value="">All Analysts</option>{reviewerOptions.map(r => <option key={r.value} value={r.value}>{r.label}</option>)}</select></label>
        <label><i className="bi bi-grid" /><select value={filter.panelName || ''} onChange={e => setFilterValue?.('panelName', e.target.value)}><option value="">All Panels</option>{panelOptions.map(p => <option key={p} value={p}>{p}</option>)}</select></label>
      </div>
      <div className="aging-actions">
        <button type="button" className="aging-btn ghost" onClick={() => { setPeriodState(''); clearFilter?.(); }}><i className="bi bi-x-circle" />Clear</button>
        <button type="button" className="aging-btn ghost" onClick={() => exportAgingWorkbook(data, buckets)}><i className="bi bi-download" />Download Excel</button>
      </div>
    </div>

    <div className="aging-main-card">
      <div className="aging-card-head">
        <div>
          <div className="aging-card-title">{config.title} / Aging Matrix</div>
          <div className="aging-card-sub">Aging is based on DenialLineItem Date of Service through the current date.</div>
        </div>
        <div className="aging-legend">
          {buckets.map((b, i) => <span key={b.key || i}><i className={bucketClasses[i] || 'h0'} />{b.label}</span>)}
        </div>
      </div>
      <div className="aging-table-wrap">
        <table className="aging-table">
          <thead>
            <tr>
              <th>{config.column}</th>
              <th className="aging-priority-col">Priority</th>
              {buckets.map((b, i) => <th key={b.key || i}><div className="aging-bucket-head"><b>{b.label}</b><span>{compactMoney(b.amount)} / {compactCount(b.claimCount)}</span></div></th>)}
              <th>Total</th>
              <th>SLA Breach</th>
            </tr>
          </thead>
          <tbody>
            {rows.length ? rows.map(row => <AgingRow key={`${pivot}-${row.name}`} row={row} buckets={buckets} onCellClick={onCellClick} pivot={pivot} />) : <tr><td colSpan={buckets.length + 4} className="empty-cell">No aging data found.</td></tr>}
            {rows.length > 0 && <tr className="aging-total-row"><td>Grand Total</td><td /><td colSpan={buckets.length} /><td className="aging-total-cell"><b>{compactMoney(totals.amount)}</b><small>/ {compactCount(totals.claims)} claims</small></td><td><span>{compactCount(totals.breaches)}</span></td></tr>}
          </tbody>
        </table>
      </div>
    </div>

    <div className="aging-bottom-grid">
      <AgingList title="Top SLA Breach" tone="red" items={data.slaRisks || []} empty="No SLA breach groups found." />
      <AgingList title="Analyst Workload Snapshot" tone="blue" items={data.analystWorkload || []} empty="No workload data found." />
    </div>
  </div>;
}

function AgingKpi({ tone, label, amount, count, delta, ok = false }) {
  return <div className={`aging-kpi aging-kpi-${tone || 'all'}`}>
    <span>{label}</span>
    <strong>{compactMoney(amount)}</strong>
    <small>{count}</small>
    <em className={ok ? 'ok' : 'warn'}>{delta}</em>
  </div>;
}

function AgingRow({ row, buckets, onCellClick, pivot }) {
  const priority = priorityMap[row.priority] || priorityMap.low;
  return <tr>
    <td>
      <div className="aging-row-name"><span className={`aging-priority ${priority.cls}`}>{priority.label}</span><div><b>{row.name || '-'}</b><small>{row.subTitle || row.name || '-'}</small></div></div>
    </td>
    <td className="aging-priority-col"><strong>{Number(row.priorityScore || 0)}</strong><i><span style={{ width: `${Math.max(4, Number(row.priorityScore || 0))}%` }} /></i></td>
    {buckets.map((b, i) => {
      const cell = getBucket(row, b.key);
      return <td key={b.key || i}><button type="button" className={`aging-cell ${bucketClasses[i] || 'h0'}`} onClick={() => onCellClick?.({ pivot, row, bucket: b })}><strong>{compactMoney(cell.amount)}</strong><small>{compactCount(cell.claimCount)} claims</small>{Number(cell.slaBreaches || 0) > 0 && <em>{compactCount(cell.slaBreaches)} at risk</em>}</button></td>;
    })}
    <td className="aging-total-cell"><b>{compactMoney(row.totalAmount)}</b><small>/ {compactCount(row.totalClaims)} claims</small></td>
    <td className="aging-breach-cell">{Number(row.slaBreaches || 0) > 0 ? <span>{compactCount(row.slaBreaches)}</span> : <small>-</small>}</td>
  </tr>;
}

function AgingList({ title, tone, items, empty }) {
  return <div className="aging-list-card">
    <div className="aging-list-title"><i className={tone} />{title}</div>
    {items.length ? items.map((item, index) => <div className="aging-list-row" key={`${title}-${item.name}-${index}`}>
      <div><b>{item.name}</b><small>{item.subTitle || item.status}</small></div>
      <strong>{compactMoney(item.amount)}</strong>
      <span>{compactCount(item.claimCount)}</span>
      <em className={String(item.status || '').toLowerCase().includes('need') || String(item.status || '').toLowerCase().includes('breach') ? 'warn' : 'ok'}>{item.status || 'On track'}</em>
    </div>) : <div className="aging-list-empty">{empty}</div>}
  </div>;
}
