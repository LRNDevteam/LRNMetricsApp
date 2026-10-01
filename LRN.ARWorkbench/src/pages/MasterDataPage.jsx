import { Badge, PageHeader } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';

const LIST_LABELS = [
  ['NON_COLLECTIBLE_CODE', 'Non-Collectible Denial Codes'],
  ['AUTO_ADJUST_CODE', 'Auto-Adjust Denial Codes'],
  ['DENIAL_CATEGORY', 'Denial Categories'],
  ['PANEL_TYPE', 'Panel Types'],
  ['DENIAL_ROOT_CAUSE', 'Denial Root Cause Options'],
  ['FIX_RESOLUTION', 'Fix / Resolution Options'],
  ['CLAIM_STATUS', 'Follow-Up Claim Statuses'],
  ['FOLLOW_UP_TYPE', 'Follow-Up Types'],
  ['CLAIM_TYPE', 'Claim Types'],
  ['CIP_CATEGORY', 'CIP Categories'],
  ['CIP_REQUIRED_INFO', 'CIP Required Information'],
  ['ESCALATION_REASON', 'Escalation Reasons'],
  ['REASSIGNMENT_REASON', 'Reassignment Reasons'],
  ['DOCUMENT_CATEGORY', 'Document Categories']
];

// Read-only in the base build. Add / remove, CSV download and upload arrive with phase 3.
export default function MasterDataPage() {
  const { masterData } = useWorkbench();
  const lists = masterData?.lists || {};
  const byStatus = masterData?.fixResolutionsByStatus || {};

  return (
    <>
      <PageHeader note="Reference lists that drive queues and follow-up capture (dbo.ARWB_MasterListItem)">
        <Badge>Editing arrives in phase 3</Badge>
      </PageHeader>

      <div className="arwb-grid arwb-grid-charts arwb-section">
        {LIST_LABELS.map(([key, label]) => (
          <div key={key} className="arwb-panel">
            <div className="arwb-panel-head">
              <h3>{label}</h3>
              <span className="arwb-card-sub">{(lists[key] || []).length} values</span>
            </div>
            <div className="arwb-panel-pad" style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
              {(lists[key] || []).map((v) => <Badge key={v} className="arwb-badge-accent">{v}</Badge>)}
              {!(lists[key] || []).length && <span className="arwb-hint">No values</span>}
            </div>
          </div>
        ))}
      </div>

      <div className="arwb-table-card">
        <div className="arwb-panel-head"><h3>Fix / Resolution by Claim Status</h3></div>
        <div className="arwb-table-wrap">
          <table className="arwb-data-table">
            <thead><tr><th>Claim status</th><th>Allowed Fix / Resolution options</th></tr></thead>
            <tbody>
              {Object.entries(byStatus).map(([status, fixes]) => (
                <tr key={status}>
                  <td><strong>{status}</strong></td>
                  <td className="wrap">{fixes.join(' · ')}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </>
  );
}
