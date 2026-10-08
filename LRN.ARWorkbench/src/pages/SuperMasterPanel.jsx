import { useEffect, useMemo, useState } from 'react';
import DataTable from '../components/DataTable';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import { ErrorBox } from '../components/Status';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// The Denial Workflow's Denial Mapper Super Master (dbo.DenialMapperSuperMaster in LRNMaster), with
// the Denial Mapper's own editor: every column, dropdowns from the Denial Mapper lists (Master
// Values page), Action Code taken from the chosen Action Category, the same required fields, and
// the same Excel template / import / export. Saves go through the Denial Workflow's repository, so
// they are audited in the Denial Mapper audit log and reach lab masters on its next Push to Labs.

const blank = {
  denialCode: '', denialDescription: '', denialClassification: '', coverageStatus: '', icdComplianceStatus: '', denialValidity: '',
  actionCode: '', actionCategory: '', task: '', recommendedAction: '', sla: '', priority: ''
};

// [form key, label, masterData list, required]
const SELECTS = [
  ['denialClassification', 'Denial Classification', 'denialClassifications', false],
  ['coverageStatus', 'Coverage Status', 'coverageStatuses', false],
  ['icdComplianceStatus', 'ICD Compliance Status', 'icdComplianceStatuses', false],
  ['denialValidity', 'Denial Validity', 'denialValidities', false],
  ['sla', 'SLA', 'slaDays', true],
  ['priority', 'Priority', 'priorities', true]
];

const REQUIRED = [['denialCode', 'Denial Code'], ['actionCategory', 'Action Category'], ['actionCode', 'Action Code'], ['task', 'Task'],
  ['recommendedAction', 'Recommended Action'], ['sla', 'SLA'], ['priority', 'Priority']];

const read = (row, key) => row?.[key] ?? row?.[key[0].toUpperCase() + key.slice(1)] ?? '';

// A value the row already holds stays selectable even when it is no longer an active list value.
const withCurrent = (options, current) => (current && !options.includes(current) ? [current, ...options] : options);

function importText(r) {
  if (r.failedCount) return `Import finished with ${fmt.count(r.failedCount)} failed row${r.failedCount === 1 ? '' : 's'}. Inserted ${fmt.count(r.insertedCount)}, updated ${fmt.count(r.updatedCount)}.`;
  return r.message || `Import complete. Inserted ${fmt.count(r.insertedCount)}, updated ${fmt.count(r.updatedCount)}, blank rows skipped ${fmt.count(r.skippedCount)}.`;
}

export default function SuperMasterPanel({ labId, setNotice, setError, onTotal }) {
  const [query, setQuery] = useState({ search: '', classification: '', page: 1, pageSize: 50, sortBy: 'denialCode', sortDesc: false });
  const [searchText, setSearchText] = useState('');
  const [data, setData] = useState({ items: [], totalCount: 0 });
  const [loading, setLoading] = useState(true);
  const [options, setOptions] = useState({ masterData: {}, classifications: [] });
  const [editor, setEditor] = useState(null);
  const [confirmDelete, setConfirmDelete] = useState(null);
  const [dialogError, setDialogError] = useState('');
  const [busy, setBusy] = useState('');
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    setLoading(true);
    arWorkbenchService.superMaster({ labId, ...query }, controller.signal)
      .then((result) => { setData(result || { items: [], totalCount: 0 }); onTotal?.(result?.totalCount ?? 0); })
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message || 'The Super Master could not be loaded.'); })
      .finally(() => { if (!controller.signal.aborted) setLoading(false); });
    return () => controller.abort();
  }, [labId, query, reloadKey]);

  useEffect(() => {
    arWorkbenchService.superMasterOptions(labId)
      .then((o) => setOptions({ masterData: o?.masterData || {}, classifications: o?.classifications || [] }))
      .catch(() => { /* the editor still opens; its dropdowns are empty until the lists load */ });
  }, [labId, reloadKey]);

  const reload = () => setReloadKey((k) => k + 1);
  const md = options.masterData;
  const actionCategories = md.actionCategories || [];
  const actionCodeFor = (category) => actionCategories.find((x) => x.actionCategory === category)?.actionCode || '';
  const classificationFilter = options.classifications.length ? options.classifications : (md.denialClassifications || []);

  // ---- editor --------------------------------------------------------------------------------

  function openEditor(row = null) {
    setDialogError('');
    if (!row) { setEditor({ id: null, form: { ...blank } }); return; }
    const form = Object.fromEntries(Object.keys(blank).map((k) => [k, read(row, k)]));
    // As the Denial Mapper: the Action Code always follows the Action Category master.
    const code = actionCodeFor(form.actionCategory);
    if (code) form.actionCode = code;
    setEditor({ id: read(row, 'id'), form });
  }

  const setField = (key, value) => setEditor((prev) => prev && {
    ...prev,
    form: { ...prev.form, [key]: value, ...(key === 'actionCategory' ? { actionCode: actionCodeFor(value) } : {}) }
  });

  async function save() {
    const missing = REQUIRED.filter(([k]) => !String(editor.form[k] || '').trim()).map(([, label]) => label);
    if (missing.length) { setDialogError(`Complete the required fields: ${missing.join(', ')}.`); return; }

    setBusy('saving');
    setDialogError('');
    try {
      const body = Object.fromEntries(Object.entries(editor.form).map(([k, v]) => [k, typeof v === 'string' ? v.trim() : v]));
      const result = editor.id
        ? await arWorkbenchService.updateSuperMaster(labId, editor.id, body)
        : await arWorkbenchService.addSuperMaster(labId, body);
      setEditor(null);
      setNotice({ kind: 'good', text: result?.message || 'Super Master mapping saved.' });
      reload();
    } catch (e) {
      setDialogError(e.message || 'The mapping could not be saved.');
    } finally {
      setBusy('');
    }
  }

  async function remove() {
    setBusy('saving');
    setDialogError('');
    try {
      const result = await arWorkbenchService.deleteSuperMaster(labId, read(confirmDelete, 'id'));
      setConfirmDelete(null);
      setEditor(null);
      setNotice({ kind: 'good', text: result?.message || 'Super Master mapping deleted.' });
      reload();
    } catch (e) {
      setDialogError(e.message || 'The mapping could not be deleted.');
    } finally {
      setBusy('');
    }
  }

  // ---- Excel -----------------------------------------------------------------------------------

  async function importFile(file) {
    if (!file || busy) return;
    setBusy('importing');
    setError('');
    setNotice({ kind: 'info', text: `Importing ${file.name} into the Super Master…` });
    try {
      const result = await arWorkbenchService.importSuperMaster(labId, file);
      setNotice({ kind: result.failedCount ? 'warning' : 'good', text: importText(result), details: (result.errors || []).slice(0, 50) });
      reload();
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
      if (kind === 'template') await arWorkbenchService.downloadSuperMasterTemplate(labId);
      else await arWorkbenchService.exportSuperMaster(labId);
    } catch (e) {
      setError(e.message || 'The download failed.');
    } finally {
      setBusy('');
    }
  }

  // ---- table -----------------------------------------------------------------------------------

  const text = (key, wrap = false, hidden = false) => ({ key, sortKey: key, wrap, defaultHidden: hidden, render: (r) => read(r, key) || <span className="text-muted-ink">—</span>, csv: (r) => read(r, key) });
  const columns = [
    { key: 'denialCode', label: 'Denial Code', sortKey: 'denialCode', render: (r) => <span className="arwb-code-chip">{read(r, 'denialCode')}</span>, csv: (r) => read(r, 'denialCode') },
    { ...text('denialDescription', true), label: 'Description' },
    { ...text('denialClassification'), label: 'Classification' },
    { ...text('coverageStatus'), label: 'Coverage' },
    { ...text('icdComplianceStatus'), label: 'ICD Compliance' },
    { ...text('denialValidity'), label: 'Validity' },
    { key: 'actionCode', label: 'Action Code', sortKey: 'actionCode', render: (r) => (read(r, 'actionCode') ? <span className="arwb-code-chip">{read(r, 'actionCode')}</span> : '—'), csv: (r) => read(r, 'actionCode') },
    { ...text('actionCategory'), label: 'Action Category' },
    { ...text('task', true), label: 'Task' },
    { ...text('recommendedAction', true), label: 'Recommended Action' },
    { ...text('sla'), label: 'SLA' },
    { ...text('priority'), label: 'Priority' },
    { key: 'modifiedOn', label: 'Last changed', sortKey: 'modifiedOn', defaultHidden: true, render: (r) => fmt.dateTime(read(r, 'modifiedOn')), csv: (r) => read(r, 'modifiedOn') },
    { key: 'actions', label: 'Actions', csv: () => '',
      render: (r) => (
        <div className="arwb-row-actions">
          <button type="button" className="arwb-icon-btn" title="Edit" aria-label={`Edit ${read(r, 'denialCode')}`} disabled={!!busy} onClick={() => openEditor(r)}><Icon name="edit" size={15} /></button>
          <button type="button" className="arwb-icon-btn danger" title="Delete" aria-label={`Delete ${read(r, 'denialCode')}`} disabled={!!busy} onClick={() => { setDialogError(''); setConfirmDelete(r); }}><Icon name="trash" size={15} /></button>
        </div>
      ) }
  ];

  const categoryOptions = useMemo(() => withCurrent(actionCategories.map((x) => x.actionCategory), editor?.form.actionCategory), [actionCategories, editor?.form.actionCategory]);

  return (
    <>
      <div className="arwb-card arwb-filter-card" style={{ marginBottom: 14 }}>
        <div className="arwb-mv-toolbar" style={{ padding: 0, border: 0 }}>
          <input type="search" className="arwb-input" value={searchText} placeholder="Search denial code or description"
            aria-label="Search the Super Master" onChange={(e) => setSearchText(e.target.value)}
            onKeyDown={(e) => { if (e.key === 'Enter') setQuery((q) => ({ ...q, search: searchText.trim(), page: 1 })); }} />
          <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setQuery((q) => ({ ...q, search: searchText.trim(), page: 1 }))}><Icon name="search" size={15} /> Search</button>
          <select className="arwb-select arwb-select-inline" style={{ width: 'auto', maxWidth: 260 }} aria-label="Denial Classification" value={query.classification}
            onChange={(e) => setQuery((q) => ({ ...q, classification: e.target.value, page: 1 }))}>
            <option value="">All classifications</option>
            {classificationFilter.map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
          {(query.search || query.classification) && (
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => { setSearchText(''); setQuery((q) => ({ ...q, search: '', classification: '', page: 1 })); }}>Clear</button>
          )}
        </div>
      </div>

      <DataTable
        tableId="super-master"
        columns={columns}
        rows={data.items || []}
        totalCount={data.totalCount}
        page={query.page}
        pageSize={query.pageSize}
        loading={loading}
        exportName="denial_super_master_page"
        emptyText={query.search || query.classification ? 'No mappings match the filters.' : 'The Super Master has no mappings yet.'}
        rowKey={(r) => read(r, 'id')}
        sortBy={query.sortBy}
        sortDesc={query.sortDesc}
        onSort={(sortBy, sortDesc) => setQuery((q) => ({ ...q, sortBy, sortDesc, page: 1 }))}
        onPage={(page) => setQuery((q) => ({ ...q, page }))}
        onPageSize={(pageSize) => setQuery((q) => ({ ...q, pageSize, page: 1 }))}
        toolbar={(
          <>
            <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!!busy} onClick={() => openEditor()}><Icon name="plus" size={15} /> Add Code</button>
            <button type="button" className="arwb-btn arwb-btn-sm" disabled={!!busy} onClick={() => download('template')}>
              {busy === 'template' ? <span className="arwb-spinner" /> : <Icon name="download" size={15} />} Template
            </button>
            <label className={`arwb-btn arwb-btn-sm arwb-upload${busy ? ' disabled' : ''}`} aria-disabled={!!busy} title="Import a Super Master workbook (the template or an export)">
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
        This is the Denial Workflow&rsquo;s central Super Master, shared by every lab. Its dropdowns come from the Denial Mapper lists on the
        Master Values page. Changes are recorded in the Denial Mapper audit log and reach each lab&rsquo;s Denial Code Master on the
        Denial Mapper&rsquo;s next <strong>Push to Labs</strong>.
      </p>

      {editor && !confirmDelete && (
        <Modal
          wide
          title={editor.id ? `Edit Denial Code ${editor.form.denialCode}` : 'Add Denial Code'}
          subtitle="Super Master · shared by every lab · required fields are marked with *"
          submitLabel={editor.id ? 'Save' : 'Add'}
          busy={busy === 'saving'}
          onClose={() => { setEditor(null); setDialogError(''); }}
          onSubmit={save}>
          <ErrorBox message={dialogError} />
          <div className="arwb-form-grid">
            <div className="arwb-field">
              <label htmlFor="sm-code">Denial Code *</label>
              <input id="sm-code" className="arwb-input" value={editor.form.denialCode} maxLength={100} placeholder="e.g. CO-4" onChange={(e) => setField('denialCode', e.target.value)} />
            </div>
            <div className="arwb-field">
              <label htmlFor="sm-category">Action Category *</label>
              <select id="sm-category" className="arwb-select" value={editor.form.actionCategory} onChange={(e) => setField('actionCategory', e.target.value)}>
                <option value="">Select Action Category</option>
                {categoryOptions.map((c) => <option key={c} value={c}>{c}</option>)}
              </select>
            </div>
            <div className="arwb-field span-2">
              <label htmlFor="sm-desc">Denial Description</label>
              <textarea id="sm-desc" className="arwb-textarea" rows={2} value={editor.form.denialDescription} placeholder="Full description…" onChange={(e) => setField('denialDescription', e.target.value)} />
            </div>
            <div className="arwb-field">
              <label htmlFor="sm-action-code">Action Code *</label>
              <input id="sm-action-code" className="arwb-input" value={editor.form.actionCode} readOnly placeholder="Selected from Action Category" />
              <div className="arwb-field-note">Set by the Action Category (Master Values · Action Category).</div>
            </div>
            {SELECTS.map(([key, label, listKey, required]) => (
              <div key={key} className="arwb-field">
                <label htmlFor={`sm-${key}`}>{label}{required ? ' *' : ''}</label>
                <select id={`sm-${key}`} className="arwb-select" value={editor.form[key]} onChange={(e) => setField(key, e.target.value)}>
                  <option value="">Select {label}</option>
                  {withCurrent(md[listKey] || [], editor.form[key]).map((x) => <option key={x} value={x}>{x}</option>)}
                </select>
              </div>
            ))}
            <div className="arwb-field span-2">
              <label htmlFor="sm-task">Task *</label>
              <input id="sm-task" className="arwb-input" value={editor.form.task} placeholder="Task description…" onChange={(e) => setField('task', e.target.value)} />
            </div>
            <div className="arwb-field span-2">
              <label htmlFor="sm-rec">Recommended Action *</label>
              <textarea id="sm-rec" className="arwb-textarea" rows={3} value={editor.form.recommendedAction} placeholder="Describe the action…" onChange={(e) => setField('recommendedAction', e.target.value)} />
            </div>
          </div>
          {editor.id && (
            <div>
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-danger" disabled={busy === 'saving'} onClick={() => { setDialogError(''); setConfirmDelete({ id: editor.id, denialCode: editor.form.denialCode }); }}>
                <Icon name="trash" size={14} /> Delete this mapping
              </button>
            </div>
          )}
        </Modal>
      )}

      {confirmDelete && (
        <Modal
          title={`Delete ${read(confirmDelete, 'denialCode')} from the Super Master?`}
          submitLabel="Delete"
          submitClass="arwb-btn-danger"
          busy={busy === 'saving'}
          onClose={() => { setConfirmDelete(null); setDialogError(''); }}
          onSubmit={remove}>
          <ErrorBox message={dialogError} />
          <p>The mapping is removed from the central Super Master for every lab. The deletion reaches lab masters on the Denial Mapper&rsquo;s next Push to Labs, and is recorded in its audit log.</p>
        </Modal>
      )}
    </>
  );
}
