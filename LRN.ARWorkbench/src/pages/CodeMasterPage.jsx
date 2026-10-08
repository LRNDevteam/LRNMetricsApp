import { useCallback, useEffect, useMemo, useState } from 'react';
import DataTable from '../components/DataTable';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import { Badge, ErrorBox, Loading, Notice } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// Master Values > Denial Code Descriptions: the central Denial Code Master (LRNMaster
// dbo.ARWB_DenialCodeMaster), one row per code WITHOUT its CO / PR / PI / OA prefix, shared by every
// lab. Holds the common description, the recommended Action Category, the Denial Mapper attributes
// (Classification, Coverage, ICD Compliance, Validity) and the Non-Collectible flag. The claim view's
// Denial tab reads it; "Apply to this lab" copies the Non-Collectible codes into the lab's list.

const BLANK = {
  denialCode: '', denialDescription: '', actionCategory: '', denialClassification: '', coverageStatus: '',
  icdComplianceStatus: '', denialValidity: '', isNonCollectible: false, isActive: true
};
const FILTERS = [
  ['all', 'All codes'],
  ['nc', 'Non-collectible'],
  ['missing', 'Missing Coverage / ICD / Validity'],
  ['inactive', 'Inactive']
];

const withCurrent = (list, current) => (current && !list.includes(current) ? [current, ...list] : list);
const dash = (v) => v || <span className="text-muted-ink">—</span>;

function NonCollectibleSyncModal({ labId, labName, onClose, onDone }) {
  const [plan, setPlan] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  useEffect(() => { arWorkbenchService.nonCollectibleSyncPreview(labId).then(setPlan).catch((e) => setError(e.message)); }, [labId]);

  async function apply() {
    setBusy(true);
    setError('');
    try { onDone(await arWorkbenchService.applyNonCollectibleSync(labId)); } catch (e) { setError(e.message); setBusy(false); }
  }

  const noChange = plan && plan.toAdd.length === 0 && plan.toDeactivate.length === 0;
  const codes = (list) => (list.length ? list.map((c) => <span key={c} className="arwb-code-chip">{c}</span>) : <span className="text-muted-ink">none</span>);
  return (
    <Modal title={`Apply Non-Collectible codes to ${labName || 'this lab'}`} wide busy={busy} busyLabel="Applying and recalculating…"
      onClose={onClose} onSubmit={plan && !noChange ? apply : onClose}
      submitLabel={plan ? (noChange ? 'Recalculate claims' : 'Apply to this lab') : null}>
      <ErrorBox message={error} />
      {!plan && !error && <Loading text="Comparing with this lab…" />}
      {plan && (
        <>
          <p>
            This lab&rsquo;s <b>Non-Collectible Denial Codes</b> list becomes the master&rsquo;s {plan.masterCodes.length} flagged code
            {plan.masterCodes.length === 1 ? '' : 's'}. Claims are then recalculated: a claim whose <b>primary</b> code is on the list moves to the
            Non-Collectible sub-queues (and can be auto-adjusted), and every claim with <b>any</b> non-collectible code gets the Non-Collectible badge.
          </p>
          <div className="arwb-form-grid">
            <div className="arwb-field"><span className="arwb-field-label">Added / switched on ({plan.toAdd.length})</span><div className="arwb-chip-row">{codes(plan.toAdd)}</div></div>
            <div className="arwb-field"><span className="arwb-field-label">Switched off ({plan.toDeactivate.length})</span><div className="arwb-chip-row">{codes(plan.toDeactivate)}</div></div>
          </div>
          <p className="arwb-hint" style={{ marginTop: 10 }}>
            {noChange ? 'The lab already matches the master; you can still recalculate its claims. ' : ''}
            Switched-off codes stay on the list as inactive. Recalculating every claim can take a minute on a large lab.
          </p>
        </>
      )}
    </Modal>
  );
}

export default function CodeMasterPage() {
  const { labId, lab } = useWorkbench();
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [busy, setBusy] = useState('');
  const [term, setTerm] = useState('');
  const [filter, setFilter] = useState('all');
  const [sort, setSort] = useState({ by: 'denialCode', desc: false });
  const [paging, setPaging] = useState({ page: 1, pageSize: 50 });
  const [editor, setEditor] = useState(null);          // { isNew, form }
  const [dialogError, setDialogError] = useState('');
  const [confirmDelete, setConfirmDelete] = useState(null);
  const [syncing, setSyncing] = useState(false);

  const load = useCallback(() => {
    setError('');
    return arWorkbenchService.codeMaster(labId).then(setData).catch((e) => setError(e.message));
  }, [labId]);
  useEffect(() => { load(); }, [load]);

  const rows = useMemo(() => {
    const q = term.trim().toLowerCase();
    const list = (data?.rows || []).filter((r) => {
      if (filter === 'nc' && !r.isNonCollectible) return false;
      if (filter === 'inactive' && r.isActive) return false;
      if (filter === 'missing' && r.coverageStatus && r.icdComplianceStatus && r.denialValidity) return false;
      return !q || [r.denialCode, r.denialDescription, r.actionCategory, r.denialClassification].some((v) => (v || '').toLowerCase().includes(q));
    });
    const key = (r) => (sort.by === 'denialCode' ? (/^\d+$/.test(r.denialCode) ? `0${r.denialCode.padStart(8, '0')}` : `1${r.denialCode}`) : String(r[sort.by] ?? '').toLowerCase());
    return [...list].sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0) * (sort.desc ? -1 : 1));
  }, [data, term, filter, sort]);

  const pageRows = rows.slice((paging.page - 1) * paging.pageSize, paging.page * paging.pageSize);
  const counts = useMemo(() => ({
    total: data?.rows.length || 0,
    nc: (data?.rows || []).filter((r) => r.isNonCollectible && r.isActive).length
  }), [data]);

  const setField = (k, v) => setEditor((e) => ({ ...e, form: { ...e.form, [k]: v } }));

  async function save() {
    if (!editor.form.denialCode.trim()) { setDialogError('Enter the denial code.'); return; }
    setBusy('saving');
    setDialogError('');
    try {
      const r = editor.isNew ? await arWorkbenchService.addCodeMasterRow(labId, editor.form) : await arWorkbenchService.updateCodeMasterRow(labId, editor.form);
      setEditor(null);
      setNotice({ kind: 'good', text: r.message });
      await load();
    } catch (e) {
      setDialogError(e.message);
    } finally {
      setBusy('');
    }
  }

  async function remove() {
    setBusy('deleting');
    setDialogError('');
    try {
      const r = await arWorkbenchService.deleteCodeMasterRow(labId, confirmDelete.denialCode);
      setConfirmDelete(null);
      setNotice({ kind: 'good', text: r.message });
      await load();
    } catch (e) {
      setDialogError(e.message);
    } finally {
      setBusy('');
    }
  }

  async function importFile(file) {
    if (!file || busy) return;
    setBusy('importing');
    setError('');
    setNotice({ kind: 'info', text: `Importing ${file.name}…` });
    try {
      const r = await arWorkbenchService.importCodeMaster(labId, file);
      setNotice({ kind: r.warnings?.length ? 'warning' : 'good', text: r.message, details: (r.warnings || []).slice(0, 50) });
      await load();
    } catch (e) {
      // A rejected import comes back with the row errors in the body.
      setNotice(e.body?.errors?.length ? { kind: 'warning', text: e.body.message || e.message, details: e.body.errors.slice(0, 50) } : null);
      if (!e.body?.errors?.length) setError(e.message || 'Import failed.');
    } finally {
      setBusy('');
    }
  }

  async function download(kind) {
    setBusy(kind);
    setError('');
    try {
      if (kind === 'template') await arWorkbenchService.downloadCodeMasterTemplate(labId);
      else await arWorkbenchService.exportCodeMaster(labId);
    } catch (e) {
      setError(e.message || 'The download failed.');
    } finally {
      setBusy('');
    }
  }

  if (!data && !error) return <Loading text="Loading denial codes…" />;
  const o = data?.options || {};

  const columns = [
    { key: 'denialCode', label: 'Code', sortKey: 'denialCode', render: (r) => <span className="arwb-code-chip">{r.denialCode}</span> },
    { key: 'denialDescription', label: 'Description', sortKey: 'denialDescription', wrap: true, render: (r) => dash(r.denialDescription) },
    { key: 'actionCategory', label: 'Action Category', sortKey: 'actionCategory', wrap: true, render: (r) => dash(r.actionCategory) },
    { key: 'denialClassification', label: 'Classification', sortKey: 'denialClassification', render: (r) => dash(r.denialClassification) },
    { key: 'coverageStatus', label: 'Coverage', sortKey: 'coverageStatus', render: (r) => dash(r.coverageStatus) },
    { key: 'icdComplianceStatus', label: 'ICD Compliance', sortKey: 'icdComplianceStatus', render: (r) => dash(r.icdComplianceStatus) },
    { key: 'denialValidity', label: 'Validity', sortKey: 'denialValidity', render: (r) => dash(r.denialValidity) },
    { key: 'isNonCollectible', label: 'Non-Collectible', sortKey: 'isNonCollectible', csv: (r) => (r.isNonCollectible ? 'Yes' : 'No'),
      render: (r) => (r.isNonCollectible ? <Badge className="arwb-badge-critical">Yes</Badge> : <span className="text-muted-ink">No</span>) },
    { key: 'isActive', label: 'Status', sortKey: 'isActive', csv: (r) => (r.isActive ? 'Active' : 'Inactive'),
      render: (r) => (r.isActive ? <Badge className="arwb-badge-good">Active</Badge> : <Badge>Inactive</Badge>) },
    { key: 'updatedOn', label: 'Last changed', sortKey: 'updatedOn', defaultHidden: true, render: (r) => fmt.dateTime(r.updatedOn || r.createdOn), csv: (r) => r.updatedOn || r.createdOn || '' },
    { key: 'actions', label: 'Actions', csv: () => '',
      render: (r) => (
        <div className="arwb-row-actions">
          <button type="button" className="arwb-icon-btn" title="Edit" aria-label={`Edit ${r.denialCode}`} disabled={!!busy}
            onClick={() => { setDialogError(''); setEditor({ isNew: false, form: { ...BLANK, ...Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v ?? (typeof BLANK[k] === 'boolean' ? false : '')])) } }); }}>
            <Icon name="edit" size={15} />
          </button>
          <button type="button" className="arwb-icon-btn danger" title="Delete" aria-label={`Delete ${r.denialCode}`} disabled={!!busy}
            onClick={() => { setDialogError(''); setConfirmDelete(r); }}><Icon name="trash" size={15} /></button>
        </div>
      ) }
  ];

  const select = (id, label, key, options) => (
    <div className="arwb-field">
      <label htmlFor={id}>{label}</label>
      <select id={id} className="arwb-select" value={editor.form[key] || ''} onChange={(e) => setField(key, e.target.value)}>
        <option value="">—</option>
        {withCurrent(options || [], editor.form[key]).map((v) => <option key={v} value={v}>{v}</option>)}
      </select>
    </div>
  );

  return (
    <>
      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} onRetry={load} />

      {data && !data.installed && (
        <div className="arwb-alert" role="alert">
          <Icon name="warn" size={16} />
          <div className="grow">The central Denial Code master is not installed yet. Run <b>LRN.ReportsApi/Sql/ArWorkbench/LRNMaster_02_ARWB_DenialCodeMaster.sql</b> in LRNMaster (it also loads the business workbook&rsquo;s codes), then reload.</div>
        </div>
      )}

      {data?.installed && (
        <>
          <div className="arwb-card arwb-filter-card" style={{ marginBottom: 14 }}>
            <div className="arwb-mv-toolbar" style={{ padding: 0, border: 0 }}>
              <input type="search" className="arwb-input" value={term} placeholder="Search code, description or category" aria-label="Search denial codes"
                onChange={(e) => { setTerm(e.target.value); setPaging((p) => ({ ...p, page: 1 })); }} />
              <select className="arwb-select arwb-select-inline" style={{ width: 'auto' }} aria-label="Show" value={filter}
                onChange={(e) => { setFilter(e.target.value); setPaging((p) => ({ ...p, page: 1 })); }}>
                {FILTERS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              </select>
              <span className="arwb-hint">{fmt.count(counts.total)} codes · {fmt.count(counts.nc)} non-collectible</span>
              <button type="button" className="arwb-btn arwb-btn-sm" style={{ marginLeft: 'auto' }} disabled={!!busy} onClick={() => setSyncing(true)}
                title="Copy the Non-Collectible codes into this lab's list and recalculate its claims">
                <Icon name="refresh" size={15} /> Apply Non-Collectible codes to {lab?.labName || 'this lab'}
              </button>
            </div>
          </div>

          <DataTable
            tableId="code-master-v1"
            exportName="denial_code_descriptions"
            columns={columns}
            rows={pageRows}
            totalCount={rows.length}
            page={paging.page}
            pageSize={paging.pageSize}
            sortBy={sort.by}
            sortDesc={sort.desc}
            rowKey={(r) => r.denialCode}
            emptyText={term || filter !== 'all' ? 'No codes match.' : 'No codes yet. Import the Denial Codes & Categorization workbook to start.'}
            onSort={(by, desc) => setSort({ by, desc })}
            onPage={(page) => setPaging((p) => ({ ...p, page }))}
            onPageSize={(pageSize) => setPaging({ page: 1, pageSize })}
            toolbar={(
              <>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!!busy}
                  onClick={() => { setDialogError(''); setEditor({ isNew: true, form: { ...BLANK } }); }}><Icon name="plus" size={15} /> Add Code</button>
                <button type="button" className="arwb-btn arwb-btn-sm" disabled={!!busy} onClick={() => download('template')}>
                  {busy === 'template' ? <span className="arwb-spinner" /> : <Icon name="download" size={15} />} Template
                </button>
                <label className={`arwb-btn arwb-btn-sm arwb-upload${busy ? ' disabled' : ''}`} aria-disabled={!!busy}
                  title="Import the Denial Codes & Categorization workbook as it is, or this screen's export">
                  {busy === 'importing' ? <><span className="arwb-spinner" /> Importing…</> : <><Icon name="upload" size={15} /> Import Excel</>}
                  <input type="file" accept=".xlsx" disabled={!!busy} onChange={(e) => { importFile(e.target.files?.[0]); e.target.value = ''; }} />
                </label>
                <button type="button" className="arwb-btn arwb-btn-sm" disabled={!!busy} onClick={() => download('export')}>
                  {busy === 'export' ? <span className="arwb-spinner" /> : <Icon name="filetext" size={15} />} Export Excel
                </button>
              </>
            )}
          />
          <p className="arwb-hint" style={{ marginTop: 10 }}>
            One row per denial code <b>without</b> its group prefix: PR4, CO4, PI4 and OA4 all use code <b>4</b>. Shared by every lab.
            Import reads columns by name, so the business workbook loads as it is: <i>Denial Code Description</i> → Description,
            <i> Denial Categorization</i> → Action Category, and a <i>Non-collectible Denials</i> sheet sets the complete Non-Collectible list.
            Columns a sheet does not have (e.g. Coverage, ICD Compliance) are left unchanged. The Classification, Coverage, ICD Compliance
            and Validity lists are the Denial Mapper lists (Master Values › Denial Mapper Lists).
          </p>
        </>
      )}

      {editor && (
        <Modal wide title={editor.isNew ? 'Add Denial Code' : `Edit Denial Code ${editor.form.denialCode}`}
          subtitle="Denial Code Descriptions · shared by every lab" submitLabel={editor.isNew ? 'Add' : 'Save'}
          busy={busy === 'saving'} onClose={() => setEditor(null)} onSubmit={save}>
          <ErrorBox message={dialogError} />
          <div className="arwb-form-grid">
            <div className="arwb-field">
              <label htmlFor="cm-code">Denial Code *</label>
              <input id="cm-code" className="arwb-input" maxLength={50} value={editor.form.denialCode} readOnly={!editor.isNew}
                placeholder="e.g. 4 (CO-4, PR4 are saved as 4)" onChange={(e) => setField('denialCode', e.target.value)} />
            </div>
            <div className="arwb-field">
              <label htmlFor="cm-action">Action Category</label>
              <input id="cm-action" className="arwb-input" list="cm-action-list" maxLength={200} value={editor.form.actionCategory}
                onChange={(e) => setField('actionCategory', e.target.value)} />
              <datalist id="cm-action-list">{(o.actionCategories || []).map((v) => <option key={v} value={v} />)}</datalist>
            </div>
            <div className="arwb-field" style={{ gridColumn: '1 / -1' }}>
              <label htmlFor="cm-desc">Description</label>
              <textarea id="cm-desc" className="arwb-input" rows={2} maxLength={1000} value={editor.form.denialDescription}
                onChange={(e) => setField('denialDescription', e.target.value)} />
            </div>
            {select('cm-class', 'Classification', 'denialClassification', o.denialClassifications)}
            {select('cm-cov', 'Coverage Status', 'coverageStatus', o.coverageStatuses)}
            {select('cm-icd', 'ICD Compliance', 'icdComplianceStatus', o.icdComplianceStatuses)}
            {select('cm-val', 'Denial Validity', 'denialValidity', o.denialValidities)}
            <div className="arwb-checkbox-row">
              <input id="cm-nc" type="checkbox" checked={editor.form.isNonCollectible} onChange={(e) => setField('isNonCollectible', e.target.checked)} />
              <label htmlFor="cm-nc">Non-collectible denial</label>
            </div>
            <div className="arwb-checkbox-row">
              <input id="cm-active" type="checkbox" checked={editor.form.isActive} onChange={(e) => setField('isActive', e.target.checked)} />
              <label htmlFor="cm-active">Active (shown on claims)</label>
            </div>
          </div>
          {editor.form.isNonCollectible && (
            <p className="arwb-hint">Labs pick up a Non-Collectible change when you use <b>Apply Non-Collectible codes</b> for that lab.</p>
          )}
        </Modal>
      )}

      {confirmDelete && (
        <Modal title={`Delete code ${confirmDelete.denialCode}?`} submitLabel="Delete" submitClass="arwb-btn-danger" busy={busy === 'deleting'}
          busyLabel="Deleting…" onClose={() => setConfirmDelete(null)} onSubmit={remove}>
          <ErrorBox message={dialogError} />
          <p>Claims with this code will no longer show its description and attributes. To keep it but hide it, untick <b>Active</b> instead.</p>
        </Modal>
      )}

      {syncing && (
        <NonCollectibleSyncModal labId={labId} labName={lab?.labName} onClose={() => setSyncing(false)}
          onDone={(r) => { setSyncing(false); setNotice({ kind: 'good', text: r.message }); }} />
      )}
    </>
  );
}
