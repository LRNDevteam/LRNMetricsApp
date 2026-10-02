import { useCallback, useEffect, useMemo, useState } from 'react';
import Icon from '../components/Icon';
import Modal from '../components/Modal';
import { Badge, ErrorBox, Loading, Notice, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// Master File Maintenance: one screen for two families of lists that share a shape - a list picker
// beside a single table, as the Denial Workflow's Workflow Master Values screen.
//   - Denial Mapper lists (central, every lab): the seven dropdowns of the Denial Mapper Super Master
//     (dbo.DenialMapperLookupMaster / dbo.DenialMapperActionCategoryMaster), maintained through the
//     Denial Workflow's own WorkflowMasterValues repository.
//   - AR Workbench lists (this lab): dbo.ARWB_MasterListItem.
//
// The API is the authority on every rule shown here (duplicates, renaming a value in use, keeping
// one active value, reserved values). The checks below only say so before a round trip and must
// agree with WorkflowMasterValueRules and ArWorkbenchMasterRules.

const STORED_LIST_KEY = 'lrn.arwb.masterValues.list';

// Mirrors ArWorkbenchMasterRules.NormalizeDenialCode: 'CO-197', 'PR 197' and '197' are one code.
function normalizeCode(value) {
  const trimmed = String(value || '').trim();
  if (!trimmed || trimmed.toUpperCase() === 'NULL') return '';
  let v = trimmed.replace(/[ \-:\t]/g, '').toUpperCase();
  if (v.length > 2 && ['CO', 'PR', 'PI', 'OA'].includes(v.slice(0, 2))) v = v.slice(2);
  return v;
}

// Mirrors the Normalize rules: "Write Off" and "Write-Off" are one value.
const normalizeValue = (list, value) => (list.isCodeList ? normalizeCode(value) : String(value || '').trim().replace(/[- /]/g, '').toUpperCase());

const records = (n, label = 'record') => `${fmt.count(n)} ${label}${n === 1 ? '' : 's'}`;

function isReserved(list, value) {
  return (list.reservedValues || []).some((r) => r.toLowerCase() === String(value).trim().toLowerCase());
}

// The Denial Workflow's response, in the same shape as the workbench lists.
function fromMapper(raw) {
  const usageAvailable = raw?.usageAvailable !== false;
  return (raw?.lists || []).map((l) => ({
    key: `mapper:${l.type}`,
    source: 'mapper',
    type: l.type,
    label: l.label,
    description: l.description,
    maxLength: l.maxLength || 100,
    formatHint: l.formatHint || '',
    hasActionCode: Boolean(l.hasActionCode),
    isCodeList: false,
    usageLabel: usageAvailable ? 'active Super Master mappings' : null,
    reservedValues: [],
    values: (l.values || []).map((v) => ({
      value: v.value, actionCode: v.actionCode || '', sortOrder: v.sortOrder ?? 0, isActive: Boolean(v.isActive), usageCount: v.usageCount || 0,
      createdOn: v.createdOn, createdBy: v.createdBy, updatedOn: v.modifiedOn, updatedBy: v.modifiedBy
    }))
  }));
}

const fromWorkbench = (raw) => (raw?.lists || []).map((l) => ({ ...l, key: `workbench:${l.type}`, source: 'workbench', hasActionCode: false }));

const GROUPS = [
  ['mapper', 'Denial Mapper lists · all labs'],
  ['workbench', 'AR Workbench lists · this lab']
];

// view (from the Master Values submenu): 'mapper' | 'workbench' - one family of lists; 'fix' - the
// Fix / Resolution by Claim Status table.
export default function MasterDataPage({ view = 'mapper' }) {
  const { labId, lab, masterData, reloadMasterData } = useWorkbench();
  const tab = view === 'fix' ? 'fix' : 'lists';
  const wantMapper = view === 'mapper';
  const wantWorkbench = view === 'workbench';
  const [lists, setLists] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [mapperNote, setMapperNote] = useState('');
  const [activeKey, setActiveKey] = useState(() => { try { return localStorage.getItem(STORED_LIST_KEY) || ''; } catch { return ''; } });
  const [search, setSearch] = useState('');
  const [showInactive, setShowInactive] = useState(true);
  const [editor, setEditor] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [dialogError, setDialogError] = useState('');
  const [rowError, setRowError] = useState('');
  const [notice, setNotice] = useState(null);
  const [saving, setSaving] = useState(false);

  // Only the family this menu item shows is loaded.
  const load = useCallback(async () => {
    setLoadError('');
    if (tab === 'fix') { setLists([]); return; }
    const [mapper, workbench] = await Promise.allSettled([
      wantMapper ? arWorkbenchService.mapperMasters(labId) : Promise.resolve(null),
      wantWorkbench ? arWorkbenchService.masterValues(labId) : Promise.resolve(null)
    ]);
    const next = [];
    if (wantMapper) {
      if (mapper.status === 'fulfilled') {
        next.push(...fromMapper(mapper.value));
        setMapperNote(mapper.value?.usageAvailable === false ? 'The Denial Mapper Super Master is not set up in this database yet, so its usage counts are not shown.' : '');
      } else {
        setMapperNote('');
        setLoadError(mapper.reason?.message || 'The Denial Mapper lists could not be loaded.');
      }
    }
    if (wantWorkbench) {
      if (workbench.status === 'fulfilled') next.push(...fromWorkbench(workbench.value));
      else setLoadError(workbench.reason?.message || 'The AR Workbench lists could not be loaded.');
    }
    setLists(next);
  }, [labId, tab, wantMapper, wantWorkbench]);

  useEffect(() => { load(); }, [load]);

  const list = lists?.find((l) => l.key === activeKey) || lists?.[0] || null;
  const activeCount = list ? list.values.filter((v) => v.isActive).length : 0;

  useEffect(() => {
    if (!list) return;
    try { localStorage.setItem(STORED_LIST_KEY, list.key); } catch { /* remembering the list is a convenience */ }
  }, [list?.key]);

  const visibleValues = useMemo(() => {
    if (!list) return [];
    const q = search.trim().toLowerCase();
    return list.values.filter((v) => (showInactive || v.isActive)
      && (!q || v.value.toLowerCase().includes(q) || (v.actionCode || '').toLowerCase().includes(q)));
  }, [list, search, showInactive]);

  const closeDialogs = useCallback(() => { setEditor(null); setConfirm(null); setDialogError(''); }, []);

  function selectList(key) {
    setActiveKey(key);
    setSearch('');
    setRowError('');
  }

  function openAdd() {
    setRowError('');
    setDialogError('');
    setEditor({ mode: 'add', original: null, usageCount: 0, reserved: false, form: { value: '', actionCode: '', sortOrder: '', isActive: true } });
  }

  function openEdit(item) {
    setRowError('');
    setDialogError('');
    setEditor({
      mode: 'edit', original: item.value, usageCount: item.usageCount, wasActive: item.isActive, reserved: isReserved(list, item.value),
      form: { value: item.value, actionCode: item.actionCode || '', sortOrder: String(item.sortOrder), isActive: item.isActive }
    });
  }

  const setField = (key, value) => setEditor((prev) => prev && { ...prev, form: { ...prev.form, [key]: value } });

  function checkBeforeSave(form) {
    const value = form.value.trim();
    if (!value) return `${list.label} value is required.`;
    if (list.isCodeList && !normalizeCode(value)) return 'Enter a denial code.';
    if (list.isCodeList && /[,;|/]/.test(value)) return 'Enter one denial code per value.';
    if (list.hasActionCode && !form.actionCode.trim()) return 'Action code is required for an action category.';
    const sort = String(form.sortOrder).trim();
    if (sort !== '' && !/^\d+$/.test(sort)) return 'Sort order must be a whole number.';
    if (editor.mode === 'edit' && editor.wasActive && !form.isActive && activeCount <= 1)
      return `${list.label} must keep at least one active value. Add or activate another value first.`;

    const key = normalizeValue(list, value);
    const clash = list.values.find((v) => v.value !== editor.original && normalizeValue(list, v.value) === key);
    if (clash) {
      const inactive = clash.isActive ? '' : ' (inactive — activate it instead)';
      return clash.value.toLowerCase() === value.toLowerCase()
        ? `"${value}" already exists in ${list.label}${inactive}.`
        : `"${value}" is the same as existing value "${clash.value}"${list.isCodeList ? ' once the CO / PR / PI / OA prefix is removed' : ' once spacing, hyphens and slashes are ignored'}${inactive}.`;
    }
    return '';
  }

  // One place that knows which API a list belongs to.
  const api = {
    add: (payload) => (list.source === 'mapper' ? arWorkbenchService.addMapperMaster : arWorkbenchService.addMasterValue)(labId, list.type, payload),
    update: (payload) => (list.source === 'mapper' ? arWorkbenchService.updateMapperMaster : arWorkbenchService.updateMasterValue)(labId, list.type, payload),
    remove: (value) => (list.source === 'mapper' ? arWorkbenchService.deleteMapperMaster : arWorkbenchService.deleteMasterValue)(labId, list.type, value)
  };

  const payloadFor = (item, overrides = {}) => ({
    originalValue: item.value,
    value: item.value,
    actionCode: list.hasActionCode ? item.actionCode : null,
    sortOrder: item.sortOrder,
    isActive: item.isActive,
    ...overrides
  });

  async function afterSave(result, fallback) {
    closeDialogs();
    setNotice({ kind: 'good', text: result?.message || fallback });
    await Promise.all([load(), list.source === 'workbench' ? reloadMasterData() : null]);
  }

  async function saveEditor() {
    const problem = checkBeforeSave(editor.form);
    if (problem) { setDialogError(problem); return; }

    const sortText = String(editor.form.sortOrder).trim();
    const payload = {
      originalValue: editor.original,
      value: editor.form.value.trim(),
      actionCode: list.hasActionCode ? editor.form.actionCode.trim() : null,
      // Blank on add places the value last; blank on edit keeps the current order.
      sortOrder: sortText === '' ? null : Number(sortText),
      isActive: editor.form.isActive
    };

    setSaving(true);
    setDialogError('');
    try {
      await afterSave(editor.mode === 'add' ? await api.add(payload) : await api.update(payload), 'Saved.');
    } catch (e) {
      setDialogError(e.message || 'The value could not be saved.');
    } finally {
      setSaving(false);
    }
  }

  async function setActive(item, isActive, fromDialog) {
    setSaving(true);
    setRowError('');
    setDialogError('');
    try {
      await afterSave(await api.update(payloadFor(item, { isActive })), 'Saved.');
    } catch (e) {
      const text = e.message || 'The value could not be updated.';
      if (fromDialog) setDialogError(text); else setRowError(text);
    } finally {
      setSaving(false);
    }
  }

  async function deleteValue(item) {
    setSaving(true);
    setDialogError('');
    try {
      await afterSave(await api.remove(item.value), 'Deleted.');
    } catch (e) {
      setDialogError(e.message || 'The value could not be deleted.');
    } finally {
      setSaving(false);
    }
  }

  const renameLocked = editor?.mode === 'edit' && (editor.usageCount > 0 || editor.reserved);
  const hasUsage = Boolean(list?.usageLabel);
  const columnCount = 5 + (hasUsage ? 1 : 0) + (list?.hasActionCode ? 1 : 0);
  const byStatus = masterData?.fixResolutionsByStatus || {};
  const isMapper = list?.source === 'mapper';

  return (
    <>
      <PageHeader note={tab === 'fix'
        ? `Claim-status rules for ${lab?.labName || 'this lab'} (dbo.ARWB_FixResolutionByStatus). Read-only.`
        : wantMapper
          ? 'Dropdown values for the Denial Mapper Super Master, shared with the Denial Workflow and every lab. Administrators only.'
          : `The AR Workbench's own reference lists for ${lab?.labName || 'this lab'} (dbo.ARWB_MasterListItem). Administrators only.`}>
        {tab === 'lists' && (
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={load} disabled={saving}>
            <Icon name="refresh" size={15} /> Refresh
          </button>
        )}
      </PageHeader>

      <Notice notice={notice} onClose={() => setNotice(null)} />
      <ErrorBox message={loadError} onRetry={load} />

      {tab === 'fix' && (
        <div className="arwb-table-card">
          <div className="arwb-panel-head"><h3>Fix / Resolution by Claim Status</h3><span className="arwb-card-sub">Which Fix / Resolution options a follow-up note offers for each claim status</span></div>
          <div className="arwb-table-wrap">
            <table className="arwb-data-table">
              <thead><tr><th>Claim status</th><th>Allowed Fix / Resolution options</th></tr></thead>
              <tbody>
                {Object.entries(byStatus).map(([status, fixes]) => (
                  <tr key={status}><td><strong>{status}</strong></td><td className="wrap">{fixes.join(' · ')}</td></tr>
                ))}
                {!Object.keys(byStatus).length && <tr><td colSpan={2}><div className="arwb-empty-state">No claim-status rules.</div></td></tr>}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {tab === 'lists' && (lists === null ? <Loading text="Loading master values…" /> : (
        <div className="arwb-mv-layout">
          <nav className="arwb-panel arwb-mv-lists" aria-label="Master lists">
            {GROUPS.filter(([source]) => source === view).map(([source, heading]) => {
              const group = lists.filter((l) => l.source === source);
              return (
                <div key={source}>
                  <div className="arwb-mv-group">{source === 'workbench' && lab?.labName ? `AR Workbench lists · ${lab.labName}` : heading}</div>
                  {!group.length && <div className="arwb-hint" style={{ padding: '2px 10px 6px' }}>No lists available.</div>}
                  {group.map((l) => {
                    const active = l.values.filter((v) => v.isActive).length;
                    return (
                      <button key={l.key} type="button" className={`arwb-mv-list-btn${list?.key === l.key ? ' active' : ''}`}
                        aria-current={list?.key === l.key ? 'true' : undefined} onClick={() => selectList(l.key)}>
                        <span>{l.label}</span>
                        <small>{active} active{l.values.length !== active ? ` · ${l.values.length - active} inactive` : ''}</small>
                      </button>
                    );
                  })}
                </div>
              );
            })}
          </nav>

          {!list ? <div className="arwb-panel arwb-panel-pad arwb-hint">No master lists are available.</div> : (
            <section className="arwb-table-card" aria-live="polite">
              <div className="arwb-panel-head">
                <div>
                  <h3>{list.label} {isMapper ? <Badge className="arwb-badge-info">All labs</Badge> : <Badge className="arwb-badge-neutral">This lab</Badge>}</h3>
                  <div className="arwb-card-sub">{list.description}</div>
                </div>
                <div className="arwb-panel-head-actions">
                  <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" onClick={openAdd} disabled={saving}>
                    <Icon name="plus" size={15} /> Add value
                  </button>
                </div>
              </div>

              {isMapper && mapperNote && <div style={{ padding: '10px 16px 0' }}><Notice notice={{ kind: 'info', text: mapperNote }} /></div>}

              <div className="arwb-mv-toolbar">
                <input type="search" className="arwb-input" value={search} placeholder={`Search ${list.label.toLowerCase()}…`}
                  aria-label={`Search ${list.label}`} onChange={(e) => setSearch(e.target.value)} />
                <label className="arwb-checkbox-row">
                  <input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} /> Show inactive
                </label>
                <span className="arwb-hint">{visibleValues.length} of {list.values.length}</span>
              </div>

              {rowError && <div style={{ padding: '10px 16px 0' }}><ErrorBox message={rowError} /></div>}

              <div className="arwb-table-wrap">
                <table className="arwb-data-table">
                  <thead>
                    <tr>
                      <th>Value</th>
                      {list.hasActionCode && <th>Action Code</th>}
                      <th className="num">Sort</th>
                      <th>Status</th>
                      {hasUsage && <th className="num" title={`Stored by ${list.usageLabel}`}>{isMapper ? 'Used in Super Master' : 'In use'}</th>}
                      <th>Last changed</th>
                      <th><span className="visually-hidden">Actions</span></th>
                    </tr>
                  </thead>
                  <tbody>
                    {visibleValues.map((item) => {
                      const lastActive = item.isActive && activeCount <= 1;
                      const inUse = item.usageCount > 0;
                      const reserved = isReserved(list, item.value);
                      return (
                        <tr key={item.value} className={item.isActive ? '' : 'arwb-row-inactive'}>
                          <td className="wrap">
                            {list.isCodeList ? <span className="arwb-code-chip">{item.value}</span> : item.value}
                            {reserved && <> <Badge className="arwb-badge-info" title="Used by the workbench's own rules: it cannot be renamed, deactivated or deleted">System</Badge></>}
                          </td>
                          {list.hasActionCode && <td><span className="arwb-code-chip">{item.actionCode}</span></td>}
                          <td className="num">{item.sortOrder}</td>
                          <td><Badge className={item.isActive ? 'arwb-badge-good' : 'arwb-badge-neutral'}>{item.isActive ? 'Active' : 'Inactive'}</Badge></td>
                          {hasUsage && <td className="num" title={inUse ? `Stored by ${fmt.count(item.usageCount)} ${list.usageLabel}` : undefined}>
                            {inUse ? fmt.count(item.usageCount) : <span className="text-muted-ink">0</span>}
                          </td>}
                          <td>
                            {fmt.dateTime(item.updatedOn || item.createdOn)}
                            {(item.updatedBy || item.createdBy) && <div className="arwb-hint">{item.updatedBy || item.createdBy}</div>}
                          </td>
                          <td>
                            <div className="arwb-row-actions">
                              <button type="button" className="arwb-icon-btn" title="Edit" aria-label={`Edit ${item.value}`} disabled={saving} onClick={() => openEdit(item)}>
                                <Icon name="edit" size={15} />
                              </button>
                              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost"
                                title={reserved ? 'A system value cannot be deactivated' : lastActive ? `The last active ${list.label} value cannot be deactivated` : undefined}
                                disabled={saving || (item.isActive && (lastActive || reserved))}
                                onClick={() => {
                                  if (!item.isActive) { setActive(item, true, false); return; }
                                  setDialogError('');
                                  setConfirm({ kind: 'deactivate', item });
                                }}>
                                {item.isActive ? 'Deactivate' : 'Activate'}
                              </button>
                              <button type="button" className="arwb-icon-btn danger"
                                title={reserved ? 'A system value cannot be deleted' : inUse ? `Used by ${fmt.count(item.usageCount)} ${list.usageLabel} — deactivate it instead` : lastActive ? `The last active ${list.label} value cannot be deleted` : 'Delete'}
                                aria-label={`Delete ${item.value}`}
                                disabled={saving || inUse || lastActive || reserved}
                                onClick={() => { setDialogError(''); setConfirm({ kind: 'delete', item }); }}>
                                <Icon name="trash" size={15} />
                              </button>
                            </div>
                          </td>
                        </tr>
                      );
                    })}
                    {!visibleValues.length && (
                      <tr><td colSpan={columnCount}><div className="arwb-empty-state">{list.values.length ? 'No values match the search.' : `${list.label} has no values yet.`}</div></td></tr>
                    )}
                  </tbody>
                </table>
              </div>

              <div className="arwb-panel-pad arwb-hint">
                {isMapper
                  ? <>These are the Denial Mapper&rsquo;s own lists, shared with the Denial Workflow and every lab: the Super Master (Denial Code Master page) offers them as dropdowns. <strong>Used in Super Master</strong> counts the active mappings that store the value. A value in use cannot be renamed or deleted — deactivate it instead: it stops being offered, and the mappings that already have it keep it. Changes are recorded in the Denial Mapper audit log.</>
                  : hasUsage
                    ? <><strong>In use</strong> counts the {list.usageLabel} that store the value as text. A value in use cannot be renamed or deleted — deactivate it instead: it stops being offered, and the records that already have it keep it. Values marked <strong>System</strong> are used by the workbench&rsquo;s own rules and are fixed.</>
                    : <>Codes are stored without the CO / PR / PI / OA group prefix, as the claim sync compares them. Claims pick up a change on the next Data Processing run, or straight away with <strong>Apply to claims</strong> on Master Values · Workbench Category Map.</>}
              </div>
            </section>
          )}
        </div>
      ))}

      {editor && list && (
        <Modal
          title={editor.mode === 'add' ? `Add ${list.label} value` : `Edit ${list.label} value`}
          subtitle={isMapper ? 'Shared with the Denial Workflow and every lab · required fields are marked with *' : 'Required fields are marked with *'}
          submitLabel={editor.mode === 'add' ? 'Add value' : 'Save changes'}
          busy={saving}
          onClose={closeDialogs}
          onSubmit={saveEditor}>
          <ErrorBox message={dialogError} />
          <div className="arwb-field">
            <label htmlFor="mv-value">{list.isCodeList ? 'Denial code' : list.label} *</label>
            <input id="mv-value" className="arwb-input" value={editor.form.value} maxLength={list.maxLength}
              readOnly={renameLocked} placeholder={list.formatHint || ''} onChange={(e) => setField('value', e.target.value)} />
            {renameLocked
              ? <div className="arwb-field-note">
                  {editor.reserved
                    ? 'Used by the workbench’s own rules, so it cannot be renamed.'
                    : `Used by ${fmt.count(editor.usageCount)} ${list.usageLabel}, so it cannot be renamed. To replace it, add the new value and deactivate this one.`}
                </div>
              : list.formatHint && <div className="arwb-field-note">{list.formatHint}.</div>}
          </div>
          {list.hasActionCode && (
            <div className="arwb-field">
              <label htmlFor="mv-code">Action code *</label>
              <input id="mv-code" className="arwb-input" value={editor.form.actionCode} maxLength={100} onChange={(e) => setField('actionCode', e.target.value)} />
              {editor.mode === 'edit' && editor.usageCount > 0 && (
                <div className="arwb-field-note">A new code applies to mappings made from now on; the {records(editor.usageCount, 'mapping')} already using this category keep their code until edited.</div>
              )}
            </div>
          )}
          <div className="arwb-field">
            <label htmlFor="mv-sort">Sort order</label>
            <input id="mv-sort" className="arwb-input" type="number" min="0" step="1" value={editor.form.sortOrder}
              placeholder={editor.mode === 'add' ? 'Leave blank to add at the end' : ''} onChange={(e) => setField('sortOrder', e.target.value)} />
            <div className="arwb-field-note">Lower numbers appear first in dropdowns.</div>
          </div>
          <label className="arwb-checkbox-row">
            <input type="checkbox" checked={editor.form.isActive} disabled={editor.reserved} onChange={(e) => setField('isActive', e.target.checked)} />
            {isMapper ? 'Active — offered in the Denial Mapper Super Master' : 'Active — offered in the workbench'}
          </label>
        </Modal>
      )}

      {confirm && list && (
        <Modal
          title={confirm.kind === 'delete' ? `Delete "${confirm.item.value}"?` : `Deactivate "${confirm.item.value}"?`}
          submitLabel={confirm.kind === 'delete' ? 'Delete' : 'Deactivate'}
          submitClass={confirm.kind === 'delete' ? 'arwb-btn-danger' : 'arwb-btn-primary'}
          busy={saving}
          onClose={closeDialogs}
          onSubmit={() => (confirm.kind === 'delete' ? deleteValue(confirm.item) : setActive(confirm.item, false, true))}>
          <ErrorBox message={dialogError} />
          {confirm.kind === 'delete'
            ? <p>This permanently removes the value from {list.label}{isMapper ? ' for every lab' : ''}. Nothing stores it. This cannot be undone — deactivating keeps it available to switch back on.</p>
            : <p>
                It will no longer be offered{isMapper ? ' in the Denial Mapper Super Master' : ' in the workbench'}.{' '}
                {confirm.item.usageCount > 0 ? `The ${fmt.count(confirm.item.usageCount)} ${list.usageLabel || 'records'} already using it keep it unchanged.` : ''}
                {' '}You can activate it again at any time.
              </p>}
        </Modal>
      )}
    </>
  );
}
