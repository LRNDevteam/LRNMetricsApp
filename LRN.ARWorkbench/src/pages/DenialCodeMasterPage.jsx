import { useCallback, useEffect, useMemo, useState } from 'react';
import { useLocation, useNavigate } from 'react-router';
import DataTable from '../components/DataTable';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import { Badge, ErrorBox, Loading, Notice, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import SuperMasterPanel from './SuperMasterPanel';

// Three tabs:
//   - Super Master: the Denial Workflow's central Denial Mapper Super Master, every column
//     (SuperMasterPanel).
//   - Workbench Category Map: below - what the AR Workbench claim sync reads to set each claim's
//     denial category.
//   - Unmapped Codes: claim codes with no active category mapping.
//
// Denial code -> denial category map (dbo.ARWB_DenialCodeCategoryMap), maintained as the Denial
// Workflow's Denial Code Master is: a searchable grid with add / edit / delete, an impact preview
// before a change that touches claims, an Excel template + import + export, and an explicit step
// that pushes the master into live claims ("Apply to claims" here, "Sync Now" there). The tab of
// unmapped codes plays the part of the workflow's Missing Denial Codes tab.
//
// The API is the authority on every rule (code normalization, duplicate codes, the category being
// on the Denial Categories list); the checks below only save a round trip.

const blankForm = { denialCode: '', denialCategory: '', denialReason: '', isActive: true };
const blankQuery = { search: '', status: 'all', category: '', sortBy: 'denialCode', sortDesc: false, page: 1, pageSize: 50 };

// Mirrors ArWorkbenchMasterRules.NormalizeDenialCode: 'CO-197', 'PR 197' and '197' are one code.
function normalizeCode(value) {
  const trimmed = String(value || '').trim();
  if (!trimmed || trimmed.toUpperCase() === 'NULL') return '';
  let v = trimmed.replace(/[ \-:\t]/g, '').toUpperCase();
  if (v.length > 2 && ['CO', 'PR', 'PI', 'OA'].includes(v.slice(0, 2))) v = v.slice(2);
  return v;
}

const claims = (n) => `${fmt.count(n)} claim${n === 1 ? '' : 's'}`;

function importSummary(r) {
  return `Import complete. Inserted: ${fmt.count(r.insertedCount)}, updated: ${fmt.count(r.updatedCount)}, unchanged: ${fmt.count(r.unchangedCount)}, ` +
    `blank rows skipped: ${fmt.count(r.skippedCount)}, merged as duplicates (same code after normalization): ${fmt.count(r.mergedDuplicateCount)}.`;
}

// The Master Values submenu item that shows each view (navigation.js).
const VIEW_PATHS = { super: '/masters/super-master', master: '/masters/category-map', unmapped: '/masters/unmapped' };

// view (from the Master Values submenu): 'super' | 'master' (workbench category map) | 'unmapped'.
export default function DenialCodeMasterPage({ view = 'super' }) {
  const { labId, masterData } = useWorkbench();
  const navigate = useNavigate();
  const location = useLocation();
  const tab = view;
  // "Find mapping" on Unmapped Codes opens the category map already searched for that code.
  const setTab = (next, search) => navigate(VIEW_PATHS[next], search ? { state: { search } } : undefined);
  const initialSearch = location.state?.search || '';
  const [superTotal, setSuperTotal] = useState(null);
  const [query, setQuery] = useState(() => ({ ...blankQuery, search: initialSearch }));
  const [searchText, setSearchText] = useState(initialSearch);
  const [data, setData] = useState({ items: [], totalCount: 0 });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState(null);
  const [unmapped, setUnmapped] = useState(null);
  const [editor, setEditor] = useState(null);
  const [preview, setPreview] = useState(null);
  const [confirmDelete, setConfirmDelete] = useState(null);
  const [confirmApply, setConfirmApply] = useState(false);
  const [dialogError, setDialogError] = useState('');
  const [busy, setBusy] = useState('');   // '' | saving | importing | applying | template | export
  const [reloadKey, setReloadKey] = useState(0);

  const categories = useMemo(() => masterData?.lists?.DENIAL_CATEGORY || [], [masterData]);

  useEffect(() => {
    if (tab !== 'master') return undefined;
    const controller = new AbortController();
    setLoading(true);
    setError('');
    arWorkbenchService.denialCodes({ labId, ...query }, controller.signal)
      .then((result) => setData(result || { items: [], totalCount: 0 }))
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message || 'Denial codes could not be loaded.'); })
      .finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [labId, query, reloadKey, tab]);

  // The category map shows how many codes are unmapped; the Unmapped Codes view lists them.
  const loadUnmapped = useCallback(() => {
    if (tab === 'super') return;
    arWorkbenchService.unmappedDenialCodes(labId)
      .then((rows) => setUnmapped(rows || []))
      .catch((e) => { setUnmapped([]); setError(e.message || 'Unmapped codes could not be loaded.'); });
  }, [labId, tab]);

  useEffect(() => { loadUnmapped(); }, [loadUnmapped]);

  const reload = () => { setReloadKey((k) => k + 1); loadUnmapped(); };
  const setFilter = (patch) => setQuery((q) => ({ ...q, ...patch, page: 1 }));
  const closeDialogs = () => { setEditor(null); setPreview(null); setConfirmDelete(null); setConfirmApply(false); setDialogError(''); };

  // ---- add / edit ------------------------------------------------------------------------------

  function openAdd(prefill = {}) {
    setDialogError('');
    setEditor({ mode: 'add', original: null, currentCategory: null, form: { ...blankForm, ...prefill } });
  }

  function openEdit(row) {
    setDialogError('');
    setEditor({
      mode: 'edit', original: row.denialCode, currentCategory: row.denialCategory, claimCount: row.claimCount,
      form: { denialCode: row.denialCode, denialCategory: row.denialCategory, denialReason: row.denialReason || '', isActive: row.isActive }
    });
  }

  const setField = (key, value) => setEditor((prev) => prev && { ...prev, form: { ...prev.form, [key]: value } });

  function checkBeforeSave(form) {
    if (!normalizeCode(form.denialCode)) return 'Denial Code is required.';
    if (/[,;|/]/.test(form.denialCode)) return 'Enter one denial code per row.';
    if (!form.denialCategory) return 'Denial Category is required.';
    return '';
  }

  // Like the workflow's Denial Code Master: before a change that reaches claims, show what it reaches.
  async function submitEditor() {
    const problem = checkBeforeSave(editor.form);
    if (problem) { setDialogError(problem); return; }
    const payload = {
      originalDenialCode: editor.original,
      denialCode: editor.form.denialCode.trim(),
      denialCategory: editor.form.denialCategory,
      denialReason: editor.form.denialReason.trim() || null,
      isActive: editor.form.isActive
    };

    setBusy('saving');
    setDialogError('');
    try {
      const impact = await arWorkbenchService.denialCodeImpact(labId, editor.original || payload.denialCode);
      if (impact?.affectedClaims > 0) {
        setPreview({ payload, mode: editor.mode, impact });
        return;
      }
      await commitSave(payload, editor.mode);
    } catch (e) {
      setDialogError(e.message || 'The impact of this change could not be checked.');
    } finally {
      setBusy('');
    }
  }

  async function commitSave(payload, mode) {
    setBusy('saving');
    setDialogError('');
    try {
      const result = mode === 'add'
        ? await arWorkbenchService.addDenialCode(labId, payload)
        : await arWorkbenchService.updateDenialCode(labId, payload);
      closeDialogs();
      setNotice({ kind: 'good', text: result?.message || 'Saved.' });
      reload();
    } catch (e) {
      // Shown in whichever dialog is open: the preview, or the editor behind it.
      setDialogError(e.message || 'The denial code could not be saved.');
      if (preview) setPreview(null);
    } finally {
      setBusy('');
    }
  }

  // ---- delete --------------------------------------------------------------------------------

  async function askDelete(row) {
    setDialogError('');
    setConfirmDelete({ row, impact: null });
    try {
      const impact = await arWorkbenchService.denialCodeImpact(labId, row.denialCode);
      setConfirmDelete((c) => c && c.row === row ? { row, impact } : c);
    } catch { /* the dialog still works without the counts */ }
  }

  async function deleteCode() {
    setBusy('saving');
    setDialogError('');
    try {
      const result = await arWorkbenchService.deleteDenialCode(labId, confirmDelete.row.denialCode);
      closeDialogs();
      setNotice({ kind: 'good', text: result?.message || 'Deleted.' });
      reload();
    } catch (e) {
      setDialogError(e.message || 'The denial code could not be deleted.');
    } finally {
      setBusy('');
    }
  }

  // ---- Excel and apply -----------------------------------------------------------------------

  async function importFile(file) {
    if (!file || busy) return;
    setBusy('importing');
    setError('');
    setNotice({ kind: 'info', text: `Importing ${file.name}…` });
    try {
      const result = await arWorkbenchService.importDenialCodes(labId, file);
      if (result.failedCount) {
        setNotice({
          kind: 'warning',
          text: `Nothing was imported: ${fmt.count(result.failedCount)} row${result.failedCount === 1 ? '' : 's'} need fixing. Correct the file and import it again.`,
          details: result.errors
        });
      } else {
        const changed = (result.insertedCount || 0) + (result.updatedCount || 0);
        setNotice({ kind: 'good', text: importSummary(result) + (changed ? ' Use Apply to claims to reclassify claims now, or they update on the next Data Processing run.' : '') });
        reload();
      }
    } catch (e) {
      setNotice(null);
      setError(e.message || 'Import failed.');
    } finally {
      setBusy('');
    }
  }

  async function download(kind) {
    setBusy(kind);
    setError('');
    try {
      if (kind === 'template') await arWorkbenchService.downloadDenialCodeTemplate(labId);
      else await arWorkbenchService.exportDenialCodes(labId);
    } catch (e) {
      setError(e.message || 'The download failed.');
    } finally {
      setBusy('');
    }
  }

  async function applyToClaims() {
    setBusy('applying');
    setDialogError('');
    try {
      const run = await arWorkbenchService.applyDenialCodes(labId);
      closeDialogs();
      if (run?.runStatus === 'Failed') {
        setError(`Apply to claims failed: ${run.errorMessage || 'see Data Processing run history.'}`);
      } else {
        setNotice({ kind: 'good', text: `Applied to claims (run #${run?.refreshRunId ?? '—'}). ${fmt.count(run?.sourceClaimRows)} claims were re-derived from the current denial code map and master lists.` });
      }
      reload();
    } catch (e) {
      setDialogError(e.message || 'Apply to claims failed.');
    } finally {
      setBusy('');
    }
  }

  // ---- table -----------------------------------------------------------------------------------

  const columns = [
    { key: 'denialCode', label: 'Denial Code', sortKey: 'denialCode', render: (r) => <span className="arwb-code-chip">{r.denialCode}</span> },
    { key: 'denialCategory', label: 'Denial Category', sortKey: 'denialCategory', wrap: true,
      render: (r) => <>{r.denialCategory}{!categories.includes(r.denialCategory) && <> <Badge className="arwb-badge-warning" title="This category is inactive or no longer on the Denial Categories list">Inactive category</Badge></>}</> },
    { key: 'denialReason', label: 'Denial Reason', sortKey: 'denialReason', wrap: true,
      csv: (r) => r.denialReason || r.workflowDescription || '',
      render: (r) => r.denialReason
        || (r.workflowDescription ? <span className="text-muted-ink" title="From this lab's Denial Workflow Denial Code Master, which the claim sync prefers">{r.workflowDescription}</span> : <span className="text-muted-ink">—</span>) },
    { key: 'claimCount', label: 'Claims', sortKey: 'claimCount', align: 'end', render: (r) => fmt.count(r.claimCount) },
    { key: 'isActive', label: 'Status', sortKey: 'isActive', csv: (r) => (r.isActive ? 'Active' : 'Inactive'),
      render: (r) => <Badge className={r.isActive ? 'arwb-badge-good' : 'arwb-badge-neutral'}>{r.isActive ? 'Active' : 'Inactive'}</Badge> },
    { key: 'updatedOn', label: 'Last changed', sortKey: 'updatedOn', defaultHidden: false, csv: (r) => r.updatedOn || r.createdOn || '',
      render: (r) => <>{fmt.dateTime(r.updatedOn || r.createdOn)}{(r.updatedBy || r.createdBy) && <div className="arwb-hint">{r.updatedBy || r.createdBy}</div>}</> },
    { key: 'actions', label: 'Actions', csv: () => '',
      render: (r) => (
        <div className="arwb-row-actions">
          <button type="button" className="arwb-icon-btn" title="Edit" aria-label={`Edit ${r.denialCode}`} disabled={!!busy} onClick={() => openEdit(r)}><Icon name="edit" size={15} /></button>
          <button type="button" className="arwb-icon-btn danger" title="Delete" aria-label={`Delete ${r.denialCode}`} disabled={!!busy} onClick={() => askDelete(r)}><Icon name="trash" size={15} /></button>
        </div>
      ) }
  ];

  const editorCategories = useMemo(() => {
    const current = editor?.currentCategory;
    return current && !categories.includes(current) ? [...categories, current] : categories;
  }, [categories, editor?.currentCategory]);

  const unmappedCount = unmapped?.length || 0;

  return (
    <>
      <PageHeader note={tab === 'super'
        ? 'The Denial Workflow’s central Denial Mapper Super Master (all labs): every denial code with its classification, coverage, ICD, validity, action, task, SLA and priority.'
        : tab === 'unmapped'
          ? 'Primary denial codes on this lab’s synced claims with no active workbench category mapping. Map them, then Apply to claims.'
          : 'The AR Workbench category map: each normalized denial code’s denial category, read by the claim sync (dbo.ARWB_DenialCodeCategoryMap).'}>
        {tab === 'super' && superTotal !== null && <Badge className="arwb-badge-neutral">{fmt.count(superTotal)} codes</Badge>}
        {tab !== 'super' && (
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!!busy} onClick={() => { setDialogError(''); setConfirmApply(true); }}>
            {busy === 'applying' ? <><span className="arwb-spinner" /> Applying…</> : <><Icon name="refresh" size={15} /> Apply to claims</>}
          </button>
        )}
      </PageHeader>

      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={error} />

      {tab === 'super' && <SuperMasterPanel labId={labId} setNotice={setNotice} setError={setError} onTotal={setSuperTotal} />}

      {tab === 'master' && (
        <>
          {unmappedCount > 0 && (
            <button type="button" className="arwb-notice arwb-notice-warning" style={{ width: '100%', textAlign: 'left', cursor: 'pointer' }} onClick={() => setTab('unmapped')}>
              <Icon name="warn" size={16} />
              <span className="grow"><strong>{unmappedCount} denial code{unmappedCount === 1 ? '' : 's'} on claims ha{unmappedCount === 1 ? 's' : 've'} no active mapping</strong> — those claims fall into &lsquo;Other&rsquo;. Review them.</span>
            </button>
          )}

          <div className="arwb-card arwb-filter-card" style={{ marginBottom: 14 }}>
            <div className="arwb-mv-toolbar" style={{ padding: 0, border: 0 }}>
              <input type="search" className="arwb-input" value={searchText} placeholder="Search code, category or reason (CO-197 finds 197)"
                aria-label="Search denial codes" onChange={(e) => setSearchText(e.target.value)}
                onKeyDown={(e) => { if (e.key === 'Enter') setFilter({ search: searchText.trim() }); }} />
              <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setFilter({ search: searchText.trim() })}><Icon name="search" size={15} /> Search</button>
              <select className="arwb-select arwb-select-inline" style={{ width: 'auto' }} aria-label="Status" value={query.status} onChange={(e) => setFilter({ status: e.target.value })}>
                <option value="all">All statuses</option>
                <option value="active">Active</option>
                <option value="inactive">Inactive</option>
              </select>
              <select className="arwb-select arwb-select-inline" style={{ width: 'auto', maxWidth: 260 }} aria-label="Category" value={query.category} onChange={(e) => setFilter({ category: e.target.value })}>
                <option value="">All categories</option>
                {categories.map((c) => <option key={c} value={c}>{c}</option>)}
              </select>
              {(query.search || query.status !== 'all' || query.category) && (
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => { setSearchText(''); setQuery((q) => ({ ...blankQuery, pageSize: q.pageSize, sortBy: q.sortBy, sortDesc: q.sortDesc })); }}>Clear</button>
              )}
            </div>
          </div>

          <DataTable
            tableId="denial-codes"
            columns={columns}
            rows={data.items || []}
            totalCount={data.totalCount}
            page={query.page}
            pageSize={query.pageSize}
            sortBy={query.sortBy}
            sortDesc={query.sortDesc}
            loading={loading}
            exportName="denial_code_master_page"
            emptyText={query.search || query.category || query.status !== 'all' ? 'No denial codes match the filters.' : 'No denial codes are mapped yet. Add one or import the Excel template.'}
            rowKey={(r) => r.denialCode}
            onSort={(sortBy, sortDesc) => setQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
            onPage={(page) => setQuery((q) => ({ ...q, page }))}
            onPageSize={(pageSize) => setQuery((q) => ({ ...q, pageSize, page: 1 }))}
            toolbar={(
              <>
                <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!!busy} onClick={() => openAdd()}><Icon name="plus" size={15} /> Add</button>
                <button type="button" className="arwb-btn arwb-btn-sm" disabled={!!busy} onClick={() => download('template')}>
                  {busy === 'template' ? <span className="arwb-spinner" /> : <Icon name="download" size={15} />} Template
                </button>
                <label className={`arwb-btn arwb-btn-sm arwb-upload${busy ? ' disabled' : ''}`} aria-disabled={!!busy} title="Import an Excel file made from the template or the export">
                  {busy === 'importing' ? <><span className="arwb-spinner" /> Importing…</> : <><Icon name="upload" size={15} /> Import Excel</>}
                  <input type="file" accept=".xlsx,.xlsm" disabled={!!busy} onChange={(e) => { importFile(e.target.files?.[0]); e.target.value = ''; }} />
                </label>
                <button type="button" className="arwb-btn arwb-btn-sm" disabled={!!busy} onClick={() => download('export')}>
                  {busy === 'export' ? <span className="arwb-spinner" /> : <Icon name="filetext" size={15} />} Export Excel
                </button>
              </>
            )}
          />
          <p className="arwb-hint" style={{ marginTop: 10 }}>
            Import adds new codes and updates existing ones; codes not in the file are left as they are. A file with any invalid row is
            rejected whole, as in the Denial Workflow. Mapping changes reach claims on the next Data Processing run, or straight away with
            <strong> Apply to claims</strong>. Claims whose category was set by hand keep it.
          </p>
        </>
      )}

      {tab === 'unmapped' && (unmapped === null ? <Loading /> : (
        <div className="arwb-table-card">
          <div className="arwb-panel-head">
            <h3>Unmapped denial codes</h3>
            <span className="arwb-card-sub">Primary denial codes on synced claims with no active mapping. Those claims are categorised &lsquo;Other&rsquo;.</span>
          </div>
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead>
                <tr><th>Denial Code</th><th>As received</th><th>Reason on claims</th><th className="num">Claims</th><th className="num">Remaining AR</th><th></th></tr>
              </thead>
              <tbody>
                {!unmapped.length && <tr><td colSpan={6}><div className="arwb-empty-state"><Icon name="check" /><div>Every denial code on the lab&rsquo;s claims is mapped.</div></div></td></tr>}
                {unmapped.map((u) => (
                  <tr key={u.denialCode}>
                    <td><span className="arwb-code-chip">{u.denialCode}</span>{u.hasInactiveMapping && <Badge className="arwb-badge-neutral" title="A mapping exists but is inactive">Inactive mapping</Badge>}</td>
                    <td>{u.sampleRawCode || '—'}</td>
                    <td className="wrap">{u.denialReason || <span className="text-muted-ink">—</span>}</td>
                    <td className="num">{fmt.count(u.claimCount)}</td>
                    <td className="num">{fmt.money(u.remainingAR)}</td>
                    <td>
                      {u.hasInactiveMapping
                        ? <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setTab('master', u.denialCode)}>Find mapping</button>
                        : <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!!busy} onClick={() => openAdd({ denialCode: u.denialCode, denialReason: u.denialReason || '' })}><Icon name="plus" size={14} /> Map</button>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ))}

      {editor && !preview && (
        <Modal
          title={editor.mode === 'add' ? 'Add Denial Code' : `Edit Denial Code ${editor.original}`}
          subtitle="Required fields are marked with *"
          submitLabel={editor.mode === 'add' ? 'Add' : 'Save'}
          busy={busy === 'saving'}
          busyLabel="Checking…"
          onClose={closeDialogs}
          onSubmit={submitEditor}>
          <ErrorBox message={dialogError} />
          <div className="arwb-field">
            <label htmlFor="dc-code">Denial Code *</label>
            <input id="dc-code" className="arwb-input" value={editor.form.denialCode} maxLength={60} placeholder="e.g. 197 or CO-197"
              onChange={(e) => setField('denialCode', e.target.value)} />
            {editor.form.denialCode && normalizeCode(editor.form.denialCode) !== editor.form.denialCode.trim() && (
              <div className="arwb-field-note">Saved as <strong>{normalizeCode(editor.form.denialCode)}</strong> — the group prefix and separators are removed, as the claim sync compares codes.</div>
            )}
          </div>
          <div className="arwb-field">
            <label htmlFor="dc-category">Denial Category *</label>
            <select id="dc-category" className="arwb-select" value={editor.form.denialCategory} onChange={(e) => setField('denialCategory', e.target.value)}>
              <option value="">Select Denial Category</option>
              {editorCategories.map((c) => <option key={c} value={c}>{c}{categories.includes(c) ? '' : ' (inactive)'}</option>)}
            </select>
            <div className="arwb-field-note">Categories come from the Denial Categories list on Master Values. The category picks the claim&rsquo;s workflow template and recommended action.</div>
          </div>
          <div className="arwb-field">
            <label htmlFor="dc-reason">Denial Reason</label>
            <textarea id="dc-reason" className="arwb-textarea" rows={3} maxLength={1000} value={editor.form.denialReason}
              onChange={(e) => setField('denialReason', e.target.value)} />
            <div className="arwb-field-note">Shown on claims when this lab&rsquo;s Denial Workflow Denial Code Master has no description for the code.</div>
          </div>
          <label className="arwb-checkbox-row">
            <input type="checkbox" checked={editor.form.isActive} onChange={(e) => setField('isActive', e.target.checked)} />
            Active — an inactive mapping is ignored and its claims fall into &lsquo;Other&rsquo;
          </label>
        </Modal>
      )}

      {preview && (
        <Modal
          title="Confirm denial code mapping change"
          subtitle="This change applies to every claim whose primary denial is this code."
          submitLabel="Confirm and save"
          busy={busy === 'saving'}
          wide
          onClose={() => { setPreview(null); setDialogError(''); }}
          onSubmit={() => commitSave(preview.payload, preview.mode)}>
          <ErrorBox message={dialogError} />
          <p>
            Denial code <strong>{preview.impact.denialCode}</strong> is the primary denial on <strong>{claims(preview.impact.affectedClaims)}</strong>
            {preview.impact.currentCategory ? <>, currently categorised <strong>{preview.impact.currentCategory}</strong></> : <>, currently in <strong>Other</strong></>}.
            Saving changes how those claims are categorised and routed when claims are next reclassified.
          </p>
          <div className="arwb-impact-counts">
            <div><span>Claims</span><strong>{fmt.count(preview.impact.affectedClaims)}</strong></div>
            <div><span>Assigned to an agent</span><strong>{fmt.count(preview.impact.assignedClaims)}</strong></div>
            <div><span>Category set by hand (kept)</span><strong>{fmt.count(preview.impact.manualCategoryClaims)}</strong></div>
            <div><span>Claim lines with the code</span><strong>{fmt.count(preview.impact.affectedLines)}</strong></div>
          </div>
          {preview.impact.queues?.length > 0 && (
            <table className="arwb-data-table">
              <thead><tr><th>AR queue</th><th className="num">Claims</th><th className="num">Assigned</th></tr></thead>
              <tbody>{preview.impact.queues.map((q) => <tr key={q.queueLabel}><td>{q.queueLabel}</td><td className="num">{fmt.count(q.claimCount)}</td><td className="num">{fmt.count(q.assignedCount)}</td></tr>)}</tbody>
            </table>
          )}
        </Modal>
      )}

      {confirmDelete && (
        <Modal
          title={`Delete denial code ${confirmDelete.row.denialCode}?`}
          submitLabel="Delete"
          submitClass="arwb-btn-danger"
          busy={busy === 'saving'}
          onClose={closeDialogs}
          onSubmit={deleteCode}>
          <ErrorBox message={dialogError} />
          <p>
            This removes the mapping to <strong>{confirmDelete.row.denialCategory}</strong>. It cannot be undone — making it inactive keeps it available to switch back on.
          </p>
          <p>
            {confirmDelete.impact === null
              ? 'Checking the claims it affects…'
              : confirmDelete.impact.affectedClaims > 0
                ? <><strong>{claims(confirmDelete.impact.affectedClaims)}</strong> ({fmt.count(confirmDelete.impact.assignedClaims)} assigned) have this primary denial and will be categorised &lsquo;Other&rsquo; when claims are next reclassified.</>
                : 'No synced claim has this primary denial.'}
          </p>
        </Modal>
      )}

      {confirmApply && (
        <Modal
          title="Apply to claims"
          subtitle="Re-derive every claim from the current master data"
          submitLabel="Apply now"
          busy={busy === 'applying'}
          busyLabel="Applying…"
          onClose={closeDialogs}
          onSubmit={applyToClaims}>
          <ErrorBox message={dialogError} />
          <p>This runs Data Processing with a full master-data reprocess. It cannot be reverted:</p>
          <ul style={{ margin: 0, paddingLeft: 18 }}>
            <li>Every claim&rsquo;s primary denial, denial category, workflow template and AR queue are re-derived from this map and the Non-Collectible / Auto-Adjust code lists.</li>
            <li>Workflow state is kept — assignments, follow-ups, QA and CIP. Claims whose category was set by hand keep it.</li>
            <li>It is also a normal weekly sync, logged in Data Processing&rsquo;s run history. A large lab can take a few minutes; keep this page open.</li>
          </ul>
        </Modal>
      )}
    </>
  );
}
