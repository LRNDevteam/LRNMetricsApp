import { useEffect, useRef, useState } from 'react';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import Icon from './Icon';
import Modal from './Modal';
import { ErrorBox } from './Status';

/**
 * Saved Views for a filter bar (dbo.ARWB_SavedView, per user and screen). The screen owns its filter
 * state: getState() returns it as a plain object to save, onApply(state) puts a saved one back.
 * The starred view is the user's default and is applied once when the screen opens, unless
 * applyDefault is false (e.g. the screen was opened from a link that carries its own filters).
 */
export default function SavedViews({ viewKey, getState, onApply, applyDefault = true }) {
  const { labId } = useWorkbench();
  const [views, setViews] = useState([]);
  const [current, setCurrent] = useState('');
  const [saving, setSaving] = useState(null);     // { name, isDefault } while the save dialog is open
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const defaultApplied = useRef(false);

  const apply = (view) => {
    try { onApply(JSON.parse(view.filtersJson || '{}')); } catch { setError('That saved view could not be read.'); }
  };

  const load = () => arWorkbenchService.savedViews(labId, viewKey).then((list) => { setViews(list); return list; });

  useEffect(() => {
    let alive = true;
    load()
      .then((list) => {
        if (!alive || defaultApplied.current) return;
        defaultApplied.current = true;
        const def = applyDefault && list.find((v) => v.isDefault);
        if (def) { setCurrent(String(def.savedViewId)); apply(def); }
      })
      .catch(() => {});   // saved views are a convenience; the screen works without them
    return () => { alive = false; };
  }, [labId, viewKey]); // eslint-disable-line react-hooks/exhaustive-deps

  const selected = views.find((v) => String(v.savedViewId) === current);

  function pick(id) {
    setCurrent(id);
    const view = views.find((v) => String(v.savedViewId) === id);
    if (view) apply(view);
  }

  async function run(action) {
    setBusy(true);
    setError('');
    try { await action(); } catch (e) { setError(e.message); } finally { setBusy(false); }
  }

  const save = () => run(async () => {
    const r = await arWorkbenchService.saveView(labId, {
      viewKey, viewName: saving.name, filtersJson: JSON.stringify(getState()), isDefault: saving.isDefault
    });
    await load();
    setCurrent(String(r.savedViewId));
    setSaving(null);
  });

  const toggleDefault = () => run(async () => {
    await arWorkbenchService.updateSavedView(labId, selected.savedViewId, { isDefault: !selected.isDefault });
    await load();
  });

  const remove = () => {
    if (!window.confirm(`Delete the saved view "${selected.viewName}"?`)) return;
    run(async () => {
      await arWorkbenchService.deleteSavedView(labId, selected.savedViewId);
      setCurrent('');
      await load();
    });
  };

  return (
    <>
      <div className="arwb-field">
        <label htmlFor={`${viewKey}-saved-view`}>Saved View</label>
        <div className="arwb-saved-views">
          <select id={`${viewKey}-saved-view`} className="arwb-select" value={current} onChange={(e) => pick(e.target.value)}>
            <option value="">{views.length ? 'Choose a view…' : 'No saved views'}</option>
            {views.map((v) => <option key={v.savedViewId} value={v.savedViewId}>{v.isDefault ? '★ ' : ''}{v.viewName}</option>)}
          </select>
          {selected && (
            <>
              <button type="button" className="arwb-icon-btn" disabled={busy} onClick={toggleDefault}
                title={selected.isDefault ? 'Stop opening this screen with this view' : 'Open this screen with this view'}
                aria-label={selected.isDefault ? 'Remove as default view' : 'Make default view'}>
                <Icon name={selected.isDefault ? 'starFill' : 'star'} size={15} />
              </button>
              <button type="button" className="arwb-icon-btn" disabled={busy} onClick={remove} title="Delete this view" aria-label="Delete view">
                <Icon name="trash" size={15} />
              </button>
            </>
          )}
          <button type="button" className="arwb-btn arwb-btn-sm" disabled={busy}
            onClick={() => { setError(''); setSaving({ name: selected?.viewName || '', isDefault: Boolean(selected?.isDefault) }); }}>
            <Icon name="save" size={15} /> Save View
          </button>
        </div>
        {error && !saving && <small className="text-critical">{error}</small>}
      </div>

      {saving && (
        <Modal title="Save View" subtitle="Saves the current filters under a name only you can see." busy={busy}
          onClose={() => setSaving(null)} onSubmit={() => { if (saving.name.trim()) save(); else setError('Give the view a name.'); }}>
          <ErrorBox message={error} />
          <div className="arwb-field">
            <label htmlFor="saved-view-name">View name</label>
            <input id="saved-view-name" className="arwb-input" maxLength={120} value={saving.name}
              onChange={(e) => setSaving((s) => ({ ...s, name: e.target.value }))} />
            {views.some((v) => v.viewName.toLowerCase() === saving.name.trim().toLowerCase()) && (
              <small className="arwb-hint">A view with this name exists; saving replaces its filters.</small>
            )}
          </div>
          <div className="arwb-checkbox-row" style={{ marginTop: 10 }}>
            <input id="saved-view-default" type="checkbox" checked={saving.isDefault}
              onChange={(e) => setSaving((s) => ({ ...s, isDefault: e.target.checked }))} />
            <label htmlFor="saved-view-default">Open this screen with this view</label>
          </div>
        </Modal>
      )}
    </>
  );
}
