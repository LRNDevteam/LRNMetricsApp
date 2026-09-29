import { PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';

const LIST_LABELS = [
  ['NON_COLLECTIBLE_CODE', 'Non-Collectible Denial Codes'],
  ['DENIAL_CATEGORY', 'Denial Categories'],
  ['PANEL_TYPE', 'Panel Types'],
  ['DENIAL_ROOT_CAUSE', 'Denial Root Cause Options'],
  ['FIX_RESOLUTION', 'Fix / Resolution Options'],
  ['CLAIM_STATUS', 'Follow-Up Claim Statuses'],
  ['FOLLOW_UP_TYPE', 'Follow-Up Types'],
  ['CLAIM_TYPE', 'Claim Types'],
  ['CIP_CATEGORY', 'CIP Categories'],
  ['CIP_REQUIRED_INFO', 'CIP Required Information']
];

// Read-only in the base build. Add / remove, CSV download and upload arrive with phase 3.
export default function MasterDataPage() {
  const { masterData } = useWorkbench();
  const lists = masterData?.lists || {};
  const byStatus = masterData?.fixResolutionsByStatus || {};

  return (
    <>
      <PageHeader note="Reference lists that drive queues and follow-up capture (arwb.MasterListItem)">
        <span className="badge text-bg-light border align-self-center">Editing arrives in phase 3</span>
      </PageHeader>

      <div className="row g-3">
        {LIST_LABELS.map(([key, label]) => (
          <div key={key} className="col-12 col-lg-6">
            <div className="arwb-card h-100">
              <h2 className="h6 d-flex justify-content-between">{label}<span className="text-secondary small fw-normal">{(lists[key] || []).length}</span></h2>
              <div className="d-flex flex-wrap gap-1">
                {(lists[key] || []).map((v) => <span key={v} className="badge text-bg-light border fw-normal arwb-chip">{v}</span>)}
                {!(lists[key] || []).length && <span className="text-secondary small">No values</span>}
              </div>
            </div>
          </div>
        ))}
        <div className="col-12">
          <div className="arwb-card">
            <h2 className="h6">Fix / Resolution by Claim Status</h2>
            <div className="table-responsive">
              <table className="table table-sm mb-0">
                <tbody>
                  {Object.entries(byStatus).map(([status, fixes]) => (
                    <tr key={status}>
                      <th className="text-nowrap" style={{ width: '14rem' }}>{status}</th>
                      <td>{fixes.join(' · ')}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
