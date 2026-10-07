import Icon from '../components/Icon';
import { PageHeader } from '../components/Status';

// What each not-yet-built route will deliver, from AR_Workbench_Open_Items_And_Phases.md.
const PLANS = {
  assignment: 'Unassigned Claims (open balance, untouched 45+ days), Create Assignment Batch with a running batch log, and Assigned Claims bulk reassign including completed claims that still carry a balance.',
  mywork: 'The signed-in agent\'s own assigned caseload.',
  followup: 'Claims due or overdue for re-follow-up: 45+ days since the last follow-up, or the next follow-up date has passed.',
  qa: 'QA review queue with bulk approve, row eligibility, and the self-approval guard.',
  'agent-requests': 'Escalate-to-Supervisor and reassignment requests from agents, with bulk resolve and one shared note.',
  cip: 'CIP case lifecycle: Pending Approval, Sent to Client, Client Responded, send back (round + 1), Returned to Agent, with bulk approve or send back.',
  'client-cip': 'Read-only CIP requests for your client, clinic or provider, with a text reply, up to three attachments, or a CSV response template.',
  audit: 'Activity trail across every claim in scope, filterable by user, action and client.',
  users: 'Add and edit workbench users, with role and access scope (all, client, clinic or provider) picked from real claim values.'
};

export default function PlannedPage({ item }) {
  return (
    <>
      <PageHeader note={`Planned for build phase ${item.phase}`} />
      <div className="arwb-card arwb-planned">
        <span style={{ color: 'var(--warning)' }}><Icon name="flag" size={26} /></span>
        <div>
          <p style={{ margin: '0 0 6px' }}>{PLANS[item.id] || 'This screen is planned.'}</p>
          <p className="arwb-hint" style={{ margin: 0 }}>The tables it needs are already in the AR Workbench database; the screen and its API endpoints come in phase {item.phase}.</p>
        </div>
      </div>
    </>
  );
}
