import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

// Admin-only maintenance for the seven lists the Denial Mapper offers: Classification, Coverage
// Status, ICD Compliance, Denial Validity, Action Category, SLA and Priority. One screen for all of
// them — the lists share a shape, so a list picker beside a single table beats seven pages.
//
// The API is the authority on every rule shown here (duplicates, renaming a value in use, keeping
// one active value). The checks below only exist to say so before a round trip, and must agree
// with WorkflowMasterValueRules / SqlWorkflowMasterValuesRepository.

const LIST_ICONS = {
  DenialClassification: 'bi-tags',
  CoverageStatus: 'bi-shield-check',
  ICDComplianceStatus: 'bi-clipboard2-pulse',
  DenialValidity: 'bi-patch-check',
  ActionCategory: 'bi-signpost-split',
  SLADays: 'bi-stopwatch',
  Priority: 'bi-flag'
};

const STORED_LIST_KEY = 'workflowMasters.type';

const read = (obj, key) => obj?.[key] ?? obj?.[key[0].toUpperCase() + key.slice(1)];

function normalizeResponse(raw) {
  const lists = (read(raw, 'lists') || []).map(list => ({
    type: read(list, 'type') || '',
    label: read(list, 'label') || '',
    description: read(list, 'description') || '',
    hasActionCode: !!read(list, 'hasActionCode'),
    maxLength: Number(read(list, 'maxLength') || 100),
    formatHint: read(list, 'formatHint') || '',
    values: (read(list, 'values') || []).map(item => ({
      value: read(item, 'value') || '',
      actionCode: read(item, 'actionCode') || '',
      sortOrder: Number(read(item, 'sortOrder') ?? 0),
      isActive: !!read(item, 'isActive'),
      usageCount: Number(read(item, 'usageCount') || 0),
      changedOn: read(item, 'modifiedOn') || read(item, 'createdOn') || null,
      changedBy: read(item, 'modifiedBy') || read(item, 'createdBy') || ''
    }))
  }));
  return { lists, usageAvailable: read(raw, 'usageAvailable') !== false };
}

// Mirrors WorkflowMasterValueRules.Normalize: "Non Covered" and "Non-Covered" are one value.
const normalizeValue = (value) => String(value || '').trim().replace(/[- /]/g, '').toUpperCase();

const mappings = (count) => `${count.toLocaleString()} active mapping${count === 1 ? '' : 's'}`;

function formatChanged(value) {
  if (!value) return '';
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

function Modal({ title, subtitle, onClose, onSubmit, submitLabel, submitClass = 'teal', busy, children }) {
  useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape' && !busy) onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [busy, onClose]);

  return <div className="modal-backdrop">
    <form className="dm-modal wm-modal" role="dialog" aria-modal="true" aria-label={title}
      onSubmit={e => { e.preventDefault(); if (!busy) onSubmit(); }}>
      <div className="dm-modal-head">
        <div><h3>{title}</h3>{subtitle && <small>{subtitle}</small>}</div>
        <button type="button" disabled={busy} onClick={onClose} aria-label="Close"><i className="bi bi-x-lg" /></button>
      </div>
      {children}
      <div className="dm-modal-actions">
        <button type="button" className="wl-btn" disabled={busy} onClick={onClose}>Cancel</button>
        <button type="submit" className={`wl-btn ${submitClass}`} disabled={busy}>
          {busy ? <><span className="dm-btn-spinner" /> Saving...</> : submitLabel}
        </button>
      </div>
    </form>
  </div>;
}

export default function WorkflowMasterValuesPage({ setMessage }) {
  const [data, setData] = useState({ lists: [], usageAvailable: true });
  const [loading, setLoading] = useState(true);
  const [loadError, setLoadError] = useState('');
  const [activeType, setActiveType] = useState(() => {
    try { return localStorage.getItem(STORED_LIST_KEY) || ''; } catch { return ''; }
  });
  const [search, setSearch] = useState('');
  const [showInactive, setShowInactive] = useState(true);
  const [editor, setEditor] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [dialogError, setDialogError] = useState('');
  const [rowError, setRowError] = useState('');
  const [saving, setSaving] = useState(false);
  const valueInputRef = useRef(null);

  const load = useCallback(async () => {
    setLoading(true);
    setLoadError('');
    try {
      setData(normalizeResponse(await denialWorkflowService.getWorkflowMasters()));
    } catch (err) {
      setLoadError(err?.message || 'Master values could not be loaded.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const list = data.lists.find(l => l.type === activeType) || data.lists[0] || null;
  const activeCount = list ? list.values.filter(v => v.isActive).length : 0;

  useEffect(() => {
    if (!list) return;
    try { localStorage.setItem(STORED_LIST_KEY, list.type); } catch { /* remembering the list is a convenience */ }
  }, [list?.type]);

  useEffect(() => {
    if (editor) setTimeout(() => valueInputRef.current?.focus(), 0);
  }, [editor?.mode, editor?.original]);

  const visibleValues = useMemo(() => {
    if (!list) return [];
    const q = search.trim().toLowerCase();
    return list.values.filter(v =>
      (showInactive || v.isActive)
      && (!q || v.value.toLowerCase().includes(q) || v.actionCode.toLowerCase().includes(q)));
  }, [list, search, showInactive]);

  const closeDialogs = useCallback(() => { setEditor(null); setConfirm(null); setDialogError(''); }, []);

  function selectList(type) {
    setActiveType(type);
    setSearch('');
    setRowError('');
  }

  function openAdd() {
    setRowError('');
    setDialogError('');
    setEditor({ mode: 'add', original: null, usageCount: 0, form: { value: '', actionCode: '', sortOrder: '', isActive: true } });
  }

  function openEdit(item) {
    setRowError('');
    setDialogError('');
    setEditor({
      mode: 'edit',
      original: item.value,
      usageCount: item.usageCount,
      wasActive: item.isActive,
      form: { value: item.value, actionCode: item.actionCode, sortOrder: String(item.sortOrder), isActive: item.isActive }
    });
  }

  function setField(key, value) {
    setEditor(prev => prev && { ...prev, form: { ...prev.form, [key]: value } });
  }

  function checkBeforeSave(form) {
    const value = form.value.trim();
    if (!value) return `${list.label} value is required.`;
    if (list.hasActionCode && !form.actionCode.trim()) return 'Action code is required for an action category.';
    if (String(form.sortOrder).trim() !== '' && !/^\d+$/.test(String(form.sortOrder).trim())) return 'Sort order must be a whole number.';
    if (editor.mode === 'edit' && editor.wasActive && !form.isActive && activeCount <= 1)
      return `${list.label} must keep at least one active value. Add or activate another value first.`;

    const key = normalizeValue(value);
    const clash = list.values.find(v => v.value !== editor.original && normalizeValue(v.value) === key);
    if (clash) {
      const inactive = clash.isActive ? '' : ' (inactive — activate it instead)';
      return clash.value.toLowerCase() === value.toLowerCase()
        ? `"${value}" already exists in ${list.label}${inactive}.`
        : `"${value}" is the same as existing value "${clash.value}" once spacing, hyphens and slashes are ignored${inactive}.`;
    }
    return '';
  }

  async function saveEditor() {
    const problem = checkBeforeSave(editor.form);
    if (problem) { setDialogError(problem); return; }

    const sortText = String(editor.form.sortOrder).trim();
    const payload = {
      originalValue: editor.original,
      value: editor.form.value.trim(),
      actionCode: list.hasActionCode ? editor.form.actionCode.trim() : null,
      // Blank on add lets the API place the value at the end; blank on edit keeps the current order.
      sortOrder: sortText === '' ? null : Number(sortText),
      isActive: editor.form.isActive
    };

    setSaving(true);
    setDialogError('');
    try {
      const result = editor.mode === 'add'
        ? await denialWorkflowService.addWorkflowMasterValue(list.type, payload)
        : await denialWorkflowService.updateWorkflowMasterValue(list.type, payload);
      closeDialogs();
      setMessage?.({ type: 'success', text: result?.message || 'Saved.' });
      await load();
    } catch (err) {
      setDialogError(err?.message || 'The value could not be saved.');
    } finally {
      setSaving(false);
    }
  }

  async function setActive(item, isActive, fromDialog) {
    setSaving(true);
    setRowError('');
    setDialogError('');
    try {
      const result = await denialWorkflowService.updateWorkflowMasterValue(list.type, {
        originalValue: item.value,
        value: item.value,
        actionCode: list.hasActionCode ? item.actionCode : null,
        sortOrder: item.sortOrder,
        isActive
      });
      closeDialogs();
      setMessage?.({ type: 'success', text: result?.message || 'Saved.' });
      await load();
    } catch (err) {
      const text = err?.message || 'The value could not be updated.';
      if (fromDialog) setDialogError(text); else setRowError(text);
    } finally {
      setSaving(false);
    }
  }

  async function deleteValue(item) {
    setSaving(true);
    setDialogError('');
    try {
      const result = await denialWorkflowService.deleteWorkflowMasterValue(list.type, item.value);
      closeDialogs();
      setMessage?.({ type: 'success', text: result?.message || 'Deleted.' });
      await load();
    } catch (err) {
      setDialogError(err?.message || 'The value could not be deleted.');
    } finally {
      setSaving(false);
    }
  }

  const renameLocked = editor?.mode === 'edit' && editor.usageCount > 0;

  return <div className="dm-page wm-page">
    <div className="dm-head">
      <div>
        <h2>Workflow Master Values</h2>
        <p>The lists the Denial Mapper offers when a denial code is mapped. Administrators only.</p>
      </div>
      <button type="button" className="wl-btn" onClick={load} disabled={loading || saving}>
        <i className={`bi bi-arrow-clockwise${loading ? ' wm-spin' : ''}`} /> Refresh
      </button>
    </div>

    {loadError && <div className="lrn-alert warning"><div>{loadError}</div></div>}
    {!data.usageAvailable && !loading && <div className="lrn-alert info">
      <div>The Denial Mapper Super Master is not set up in this database yet, so usage counts are not shown.</div>
    </div>}

    <div className="wm-layout">
      <nav className="wm-lists" aria-label="Master lists">
        {data.lists.map(l => {
          const active = l.values.filter(v => v.isActive).length;
          return <button key={l.type} type="button" className={`wm-list-btn${list?.type === l.type ? ' active' : ''}`}
            aria-current={list?.type === l.type ? 'true' : undefined} onClick={() => selectList(l.type)}>
            <i className={`bi ${LIST_ICONS[l.type] || 'bi-list-ul'}`} aria-hidden="true" />
            <span className="wm-list-text">
              <span className="wm-list-label">{l.label}</span>
              <small>{active} active{l.values.length !== active ? ` · ${l.values.length - active} inactive` : ''}</small>
            </span>
          </button>;
        })}
        {loading && !data.lists.length && <div className="wm-lists-empty">Loading lists…</div>}
      </nav>

      <section className="wm-panel" aria-live="polite">
        {!list
          ? <div className="wm-empty-panel">{loading ? 'Loading master values…' : 'No master lists are available.'}</div>
          : <>
            <header className="wm-panel-head">
              <div>
                <h3><i className={`bi ${LIST_ICONS[list.type] || 'bi-list-ul'}`} aria-hidden="true" /> {list.label}</h3>
                <p>{list.description}</p>
              </div>
              <button type="button" className="wl-btn teal" onClick={openAdd} disabled={saving}>
                <i className="bi bi-plus-lg" /> Add value
              </button>
            </header>

            <div className="wm-toolbar">
              <label className="wm-search">
                <i className="bi bi-search" aria-hidden="true" />
                <input type="search" value={search} placeholder={`Search ${list.label.toLowerCase()}…`}
                  aria-label={`Search ${list.label}`} onChange={e => setSearch(e.target.value)} />
              </label>
              <label className="wm-check">
                <input type="checkbox" checked={showInactive} onChange={e => setShowInactive(e.target.checked)} />
                <span>Show inactive</span>
              </label>
              <span className="wm-count">{visibleValues.length} of {list.values.length}</span>
            </div>

            {rowError && <div className="lrn-alert warning wm-row-error"><div>{rowError}</div></div>}

            <div className="wm-table-wrap">
              <table className="lrn-table wm-table">
                <thead>
                  <tr>
                    <th>Value</th>
                    {list.hasActionCode && <th>Action Code</th>}
                    <th className="wm-num">Sort</th>
                    <th>Status</th>
                    <th className="wm-num">Used in Super Master</th>
                    <th>Last changed</th>
                    <th className="wm-actions-col"><span className="visually-hidden">Actions</span></th>
                  </tr>
                </thead>
                <tbody>
                  {visibleValues.map(item => {
                    const lastActive = item.isActive && activeCount <= 1;
                    const inUse = item.usageCount > 0;
                    return <tr key={item.value} className={item.isActive ? '' : 'wm-inactive'}>
                      <td className="wm-value">{item.value}</td>
                      {list.hasActionCode && <td><code className="wm-code">{item.actionCode}</code></td>}
                      <td className="wm-num">{item.sortOrder}</td>
                      <td><span className={`dm-badge ${item.isActive ? 'inherited' : 'pending'}`}>{item.isActive ? 'Active' : 'Inactive'}</span></td>
                      <td className="wm-num">
                        {!data.usageAvailable ? '—' : inUse ? <span className="wm-usage" title={`Stored by ${mappings(item.usageCount)}`}>{item.usageCount.toLocaleString()}</span> : <span className="wm-muted">0</span>}
                      </td>
                      <td className="wm-changed">
                        {formatChanged(item.changedOn) || <span className="wm-muted">—</span>}
                        {item.changedBy && <small>{item.changedBy}</small>}
                      </td>
                      <td>
                        <div className="dm-actions wm-row-actions">
                          <button type="button" title="Edit" aria-label={`Edit ${item.value}`} disabled={saving} onClick={() => openEdit(item)}>
                            <i className="bi bi-pencil" />
                          </button>
                          <button type="button"
                            title={item.isActive ? (lastActive ? `The last active ${list.label} value cannot be deactivated` : 'Deactivate') : 'Activate'}
                            aria-label={`${item.isActive ? 'Deactivate' : 'Activate'} ${item.value}`}
                            disabled={saving || lastActive}
                            onClick={() => {
                              if (!item.isActive) { setActive(item, true, false); return; }
                              setDialogError('');
                              setConfirm({ kind: 'deactivate', item });
                            }}>
                            <i className={`bi ${item.isActive ? 'bi-toggle-on' : 'bi-toggle-off'}`} />
                          </button>
                          <button type="button" className="wm-danger"
                            title={inUse ? `Used by ${mappings(item.usageCount)} — deactivate it instead` : lastActive ? `The last active ${list.label} value cannot be deleted` : 'Delete'}
                            aria-label={`Delete ${item.value}`}
                            disabled={saving || inUse || lastActive}
                            onClick={() => { setDialogError(''); setConfirm({ kind: 'delete', item }); }}>
                            <i className="bi bi-trash" />
                          </button>
                        </div>
                      </td>
                    </tr>;
                  })}
                  {!visibleValues.length && <tr>
                    <td colSpan={list.hasActionCode ? 7 : 6} className="wm-empty-row">
                      {list.values.length ? 'No values match the search.' : `${list.label} has no values yet.`}
                    </td>
                  </tr>}
                </tbody>
              </table>
            </div>

            <p className="wm-footnote">
              <i className="bi bi-info-circle" aria-hidden="true" /> <strong>Used in Super Master</strong> counts active Denial Mapper
              mappings that store the value. A value in use cannot be renamed or deleted — deactivate it instead: it stops being
              offered for new mappings, and the mappings that already have it keep it. Changes reach the Denial Mapper on its next
              load. Each lab's Denial Action Master lists the values found in that lab's own data and is not changed here.
            </p>
          </>}
      </section>
    </div>

    {editor && list && <Modal
      title={editor.mode === 'add' ? `Add ${list.label} value` : `Edit ${list.label} value`}
      subtitle="Required fields are marked with *"
      submitLabel={editor.mode === 'add' ? 'Add value' : 'Save changes'}
      busy={saving}
      onClose={closeDialogs}
      onSubmit={saveEditor}>
      <div className="dm-mock-form">
        {dialogError && <div className="lrn-alert warning wm-dialog-error"><div>{dialogError}</div></div>}
        <label>
          <span>{list.label} *</span>
          <input ref={renameLocked ? null : valueInputRef} type="text" value={editor.form.value} maxLength={list.maxLength}
            readOnly={renameLocked} aria-readonly={renameLocked || undefined}
            placeholder={list.formatHint || ''} onChange={e => setField('value', e.target.value)} />
          {renameLocked
            ? <small className="wm-field-note">Used by {mappings(editor.usageCount)}, so it cannot be renamed. To replace it, add the new value and deactivate this one.</small>
            : list.formatHint && <small className="wm-field-note">{list.formatHint}.</small>}
        </label>
        {list.hasActionCode && <label>
          <span>Action code *</span>
          <input ref={renameLocked ? valueInputRef : null} type="text" value={editor.form.actionCode} maxLength={100}
            onChange={e => setField('actionCode', e.target.value)} />
          {editor.mode === 'edit' && editor.usageCount > 0 && <small className="wm-field-note">
            A new code applies to mappings made from now on; the {mappings(editor.usageCount)} already using this category keep their code until edited.
          </small>}
        </label>}
        <label>
          <span>Sort order</span>
          <input type="number" min="0" step="1" value={editor.form.sortOrder}
            placeholder={editor.mode === 'add' ? 'Leave blank to add at the end' : ''}
            onChange={e => setField('sortOrder', e.target.value)} />
          <small className="wm-field-note">Lower numbers appear first in the Denial Mapper.</small>
        </label>
        <label className="wm-check wm-check-field">
          <input type="checkbox" checked={editor.form.isActive} onChange={e => setField('isActive', e.target.checked)} />
          <span>Active — offered in the Denial Mapper</span>
        </label>
      </div>
    </Modal>}

    {confirm && list && <Modal
      title={confirm.kind === 'delete' ? `Delete "${confirm.item.value}"?` : `Deactivate "${confirm.item.value}"?`}
      submitLabel={confirm.kind === 'delete' ? 'Delete' : 'Deactivate'}
      submitClass={confirm.kind === 'delete' ? 'danger' : 'teal'}
      busy={saving}
      onClose={closeDialogs}
      onSubmit={() => confirm.kind === 'delete' ? deleteValue(confirm.item) : setActive(confirm.item, false, true)}>
      <div className="dm-mock-form">
        {dialogError && <div className="lrn-alert warning wm-dialog-error"><div>{dialogError}</div></div>}
        {confirm.kind === 'delete'
          ? <p className="wm-confirm-text">This permanently removes the value from {list.label}. No Super Master mapping uses it. This cannot be undone — deactivating keeps it available to switch back on.</p>
          : <p className="wm-confirm-text">
            It will no longer be offered in the Denial Mapper.{' '}
            {confirm.item.usageCount > 0
              ? <>The {mappings(confirm.item.usageCount)} already using it keep it unchanged.</>
              : 'No Super Master mapping uses it.'}
            {' '}You can activate it again at any time.
          </p>}
      </div>
    </Modal>}
  </div>;
}
