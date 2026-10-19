import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router';
import { DocumentTable, useDocumentTypes } from '../components/Documents';
import { ErrorBox, Loading } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';

// Document Vault (handoff §8.2, test report DEF-14): every document on the claims in the user's
// scope - follow-up attachments and client CIP responses - searchable by claim / visit (accession),
// patient and category. Client users only ever see CIP-response documents (the API enforces it).

const PAGE_SIZE = 50;

export default function DocumentVaultPage() {
  const { labId, masterData } = useWorkbench();
  const navigate = useNavigate();
  const { types } = useDocumentTypes();
  // New uploads carry their document type's category; older ones a lab DOCUMENT_CATEGORY value.
  const categories = useMemo(() => [...new Set([
    ...types.map((t) => t.documentCategory), ...(masterData?.lists?.DOCUMENT_CATEGORY || [])
  ])], [types, masterData]);
  const [filter, setFilter] = useState({ search: '', category: '', source: '', from: '', to: '' });
  const [applied, setApplied] = useState(filter);
  const [page, setPage] = useState(1);
  const [data, setData] = useState(null);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!labId) return undefined;
    const ctrl = new AbortController();
    setError('');
    setData(null);
    arWorkbenchService.documentVault({
      labId, page, pageSize: PAGE_SIZE,
      search: applied.search || undefined, category: applied.category || undefined, source: applied.source || undefined,
      from: applied.from || undefined, to: applied.to || undefined
    }, ctrl.signal)
      .then(setData)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message || 'The documents could not be loaded.'); });
    return () => ctrl.abort();
  }, [labId, page, applied]);

  const set = (k, v) => setFilter((f) => ({ ...f, [k]: v }));
  const search = (e) => { e?.preventDefault(); setPage(1); setApplied(filter); };
  const clear = () => { const empty = { search: '', category: '', source: '', from: '', to: '' }; setFilter(empty); setApplied(empty); setPage(1); };
  const pages = data ? Math.max(1, Math.ceil(data.totalCount / PAGE_SIZE)) : 1;

  return (
    <>
      <form className="arwb-card" style={{ marginBottom: 12 }} onSubmit={search}>
        <div className="arwb-form-grid">
          <div className="arwb-field span-2">
            <label htmlFor="dv-search">Claim / Visit / Patient</label>
            <input id="dv-search" className="arwb-input" maxLength={200} placeholder="Claim ID, accession (visit) number, patient name or account, file name, document type"
              value={filter.search} onChange={(e) => set('search', e.target.value)} />
          </div>
          <div className="arwb-field">
            <label htmlFor="dv-cat">Category</label>
            <select id="dv-cat" className="arwb-select" value={filter.category} onChange={(e) => set('category', e.target.value)}>
              <option value="">All categories</option>
              {categories.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          </div>
          <div className="arwb-field">
            <label htmlFor="dv-src">Source</label>
            <select id="dv-src" className="arwb-select" value={filter.source} onChange={(e) => set('source', e.target.value)}>
              <option value="">All</option>
              <option value="FollowUp">Follow-up attachments</option>
              <option value="CipResponse">CIP responses</option>
            </select>
          </div>
          <div className="arwb-field">
            <label htmlFor="dv-from">Uploaded from</label>
            <input id="dv-from" type="date" className="arwb-input" value={filter.from} onChange={(e) => set('from', e.target.value)} />
          </div>
          <div className="arwb-field">
            <label htmlFor="dv-to">Uploaded to</label>
            <input id="dv-to" type="date" className="arwb-input" value={filter.to} onChange={(e) => set('to', e.target.value)} />
          </div>
        </div>
        <div style={{ display: 'flex', gap: 8 }}>
          <button type="submit" className="arwb-btn arwb-btn-primary arwb-btn-sm">Search</button>
          <button type="button" className="arwb-btn arwb-btn-sm" onClick={clear}>Clear</button>
        </div>
      </form>

      <ErrorBox message={error} />
      {!data && !error && <Loading text="Loading documents…" />}
      {data && (
        <>
          <div className="arwb-hint" style={{ marginBottom: 8 }}>{fmt.count(data.totalCount)} document{data.totalCount === 1 ? '' : 's'}</div>
          <DocumentTable rows={data.items} showClaim onOpenClaim={(d) => navigate(`/claims/${d.claimKey}`)} />
          {pages > 1 && (
            <div className="arwb-flex-between" style={{ marginTop: 8 }}>
              <button type="button" className="arwb-btn arwb-btn-sm" disabled={page <= 1} onClick={() => setPage((p) => p - 1)}>Previous</button>
              <span className="arwb-hint">Page {page} of {pages}</span>
              <button type="button" className="arwb-btn arwb-btn-sm" disabled={page >= pages} onClick={() => setPage((p) => p + 1)}>Next</button>
            </div>
          )}
        </>
      )}
    </>
  );
}
