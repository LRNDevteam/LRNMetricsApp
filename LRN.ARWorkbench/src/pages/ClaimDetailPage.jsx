import { useEffect, useState } from 'react';
import { Link, useLocation, useParams } from 'react-router';
import AgentRequestModal from '../components/AgentRequestModal';
import AssignModal from '../components/AssignModal';
import AutoAdjustModal from '../components/AutoAdjustModal';
import { Attachments } from '../components/CipShared';
import FollowUpModal from '../components/FollowUpModal';
import QaDecisionModal, { QA_CRITERIA } from '../components/QaDecisionModal';
import Icon from '../components/Icon';
import useTableSort from '../components/useTableSort';
import { AgentName, Badge, ErrorBox, Loading, Notice, QueueBadge, StatusBadge } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { arQueueBadgeClass, fmt } from '../utils/format';

// Layout and styling follow the mockup's claim workspace (docs/Denial_WorkFlow/
// LRN_Denial_AR_Workbench_Demo_Account.html, claimdetail.js). The claim record arrives as a
// dictionary of dbo.ARWB_vw_ClaimWorklist columns (PascalCase keys).
const PHASES = ['Identified', 'Assigned', 'QA Verification', 'Completed'];
const PHASE_OF_STATUS = { Unassigned: 0, Assigned: 1, 'Submitted for QA': 2, 'QA Rejected': 2, Completed: 3 };

const BACK_LABELS = { '/my-work': 'My Work', '/qa': 'QA Verification Queue', '/audit': 'Audit Logs', '/cip': 'CIP Escalations', '/agent-requests': 'Escalation & Reassignment Requests' };

// The mockup's CORRECTIVE_ACTION text per denial category.
const CORRECTIVE_ACTION = {
  'Additional Documentation Required': 'Gather and submit the requested medical records / clinical documentation to the payer.',
  'Medical Necessity': 'Review clinical documentation for medical necessity support; file appeal with supporting notes if warranted.',
  'Coding-Related Denials': 'Correct the CPT/modifier/diagnosis combination and resubmit a corrected claim.',
  'Eligibility Issues': 'Re-verify patient eligibility and coordination of benefits; rebill correct payer if identified.',
  'Authorization Required': 'Obtain/confirm the missing referral or prior authorization and resubmit.',
  'Timely Filing': 'Document proof of timely submission and file a timely-filing exception appeal.',
  'Duplicate Claims': 'Confirm whether this is a true duplicate; void or provide original claim reference if not.',
  'Payer Processing Issues': 'Contact payer to confirm claim receipt and expedite processing.',
  'Partially Paid Claims': 'Validate the expected allowable against the contract and file an underpayment appeal if warranted.',
  'Unresponsive Payers': 'Escalate follow-up with the payer provider line; consider a formal status inquiry.',
  Other: 'Review payer remittance remarks and determine the appropriate corrective action.'
};

const RECOVERY_BADGE = {
  'In Progress': 'arwb-badge-info', 'Partially Recovered': 'arwb-badge-warning', 'Fully Recovered': 'arwb-badge-good', 'No Recovery': 'arwb-badge-critical'
};

function lineStatusBadge(status) {
  const s = (status || '').toLowerCase();
  if (s.includes('paid') && !s.includes('partial')) return 'arwb-badge-good';
  if (s.includes('denied')) return 'arwb-badge-critical';
  return 'arwb-badge-warning';
}

export default function ClaimDetailPage() {
  const { claimKey } = useParams();
  const location = useLocation();
  const { labId, can, user } = useWorkbench();
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState('');
  const [tab, setTab] = useState('overview');
  const [dialog, setDialog] = useState(null);   // 'followup' | 'assign' | 'autoadjust'
  const [notice, setNotice] = useState(null);
  const [reloadKey, setReloadKey] = useState(0);

  useEffect(() => {
    const controller = new AbortController();
    if (reloadKey === 0) setDetail(null);
    setError('');
    arWorkbenchService.claim(labId, claimKey, controller.signal)
      .then(setDetail)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); });
    return () => controller.abort();
  }, [labId, claimKey, reloadKey]);

  const [posting, setPosting] = useState(false);
  async function markPosted() {
    setPosting(true);
    try {
      const r = await arWorkbenchService.markAdjustmentsPosted(labId, [Number(claimKey)]);
      done(r?.message || 'Marked as posted.', 'activity');
    } catch (e) {
      setNotice({ kind: 'warning', text: e.message });
    } finally {
      setPosting(false);
    }
  }

  function done(message, nextTab) {
    setDialog(null);
    setNotice({ kind: 'good', text: message });
    if (nextTab) setTab(nextTab);
    setReloadKey((k) => k + 1);
  }

  const backTo = location.state?.from || '/work-queue';
  const backLabel = BACK_LABELS[backTo.split('?')[0]] || 'Work Queue';
  const back = <Link to={backTo} className="arwb-btn arwb-btn-sm arwb-btn-ghost" style={{ marginBottom: 12, textDecoration: 'none' }}>← Back to {backLabel}</Link>;

  if (error) return <>{back}<ErrorBox message={error} /></>;
  if (!detail) return <Loading />;

  const c = detail.claim;
  const phase = PHASE_OF_STATUS[c.WorkflowStatus] ?? 0;
  const agent = c.AssignedAgentName || c.AssignedAgentUser;
  const tabs = [
    ['overview', 'Overview'],
    ['cpt', 'CPT / Line Detail'],
    ['denial', 'Denial Info'],
    ['followups', `Follow-Ups (${detail.followUps.length})`],
    ['activity', 'Activity Timeline'],
    ...(detail.qaReview ? [['qa', 'QA Review']] : []),
    ...(detail.cipCases?.length ? [['cip', `CIP Case${detail.cipCases.length > 1 ? `s (${detail.cipCases.length})` : ''}`]] : []),
    ...(detail.agentRequests?.length ? [['requests', `Requests (${detail.agentRequests.length})`]] : [])
  ];

  // Escalate to Supervisor / Request Reassignment are the AR agent's way to ask a lead for help (as
  // the mockup: agent-only - leads and managers can assign themselves). One open request per kind.
  const isAgent = user?.roleCode === 'agent' && !user?.siteAdmin;
  const pendingOf = (type) => (detail.agentRequests || []).some((r) => r.requestType === type && r.requestStatus === 'Pending');
  const canRequest = isAgent && can('editClaim') && !c.IsFinanciallyClosed;

  // As the mockup: no note while one waits for QA, or on a closed claim unless it was handed to an
  // agent ad hoc. The API enforces the same rules.
  const canLog = can('editClaim') && c.WorkflowStatus !== 'Submitted for QA' && (!c.IsFinanciallyClosed || c.AdHocFollowUpAssigned);
  const logBlockedReason = c.WorkflowStatus === 'Submitted for QA' ? 'The last follow-up note is waiting for QA review.'
    : c.IsFinanciallyClosed ? 'The claim is financially closed.' : '';

  return (
    <>
      {back}
      <Notice notice={notice} onClose={() => setNotice(null)} />

      <div className="arwb-card arwb-section">
        <div className="arwb-claim-head" style={{ marginBottom: 0 }}>
          <div className="ident">
            <div className="arwb-claim-id-big">{c.ClaimID}</div>
            <div className="arwb-meta-row">
              <StatusBadge status={c.WorkflowStatus} />
              <Badge className={arQueueBadgeClass(c.ArQueueId)}>{c.ArSubQueueLabel || c.ArQueueLabel}</Badge>
              {c.Priority && <span className={`priority-${c.Priority}`}>● {c.Priority} priority</span>}
              {c.IsTflRisk && <Badge className="arwb-badge-critical" dot>TFL At Risk</Badge>}
              {(c.HasNonCollectibleDenial || c.IsNonCollectible) && (
                <Badge className="arwb-badge-critical" dot title="A denial code on this claim is on the Non-Collectible list">Non-Collectible</Badge>
              )}
              {c.PendingAgentRequests > 0 && <Badge className="arwb-badge-warning" dot>Request — Pending</Badge>}
              {!c.IsInCurrentSource && <Badge>Not in latest source file</Badge>}
              <span className="text-muted-ink">{c.LabName}</span>
            </div>
          </div>
          <div className="arwb-claim-actions">
            {can('assign') && c.IsAutoAdjustEligible && (
              <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setDialog('autoadjust')}
                title="Non-collectible denial: write off the insurance balance automatically">Process Automatic Adjustment</button>
            )}
            {can('assign') && c.ArQueueId === 'autoadj' && (
              <button type="button" className="arwb-btn arwb-btn-sm" disabled={posting} onClick={markPosted}
                title="The adjustment / write-off has been posted in the PMS">{posting ? 'Saving…' : 'Mark as Posted'}</button>
            )}
            {can('assign') && <button type="button" className="arwb-btn arwb-btn-sm" onClick={() => setDialog('assign')}>{agent ? 'Reassign' : 'Assign'}</button>}
            {canRequest && (
              <>
                <button type="button" className="arwb-btn arwb-btn-sm" disabled={pendingOf('Escalation to Supervisor')}
                  title={pendingOf('Escalation to Supervisor') ? 'An escalation on this claim is already waiting for a supervisor.' : 'Ask a Team Lead / RCM Manager for help'}
                  onClick={() => setDialog('escalate')}>
                  <Icon name="flag" size={15} /> Escalate to Supervisor
                </button>
                <button type="button" className="arwb-btn arwb-btn-sm" disabled={pendingOf('Reassignment Request')}
                  title={pendingOf('Reassignment Request') ? 'A reassignment request on this claim is already waiting.' : 'Ask a lead to give this claim to another agent'}
                  onClick={() => setDialog('reassignment')}>
                  <Icon name="users" size={15} /> Request Reassignment
                </button>
              </>
            )}
            {can('editClaim') && (
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled={!canLog} title={canLog ? undefined : logBlockedReason}
                onClick={() => setDialog('followup')}>Log Follow-Up Note</button>
            )}
          </div>
        </div>
        <PatientStrip patient={detail.patient} claim={c} />
        <hr className="arwb-divider" />
        <div className="arwb-wf-stepper">
          {PHASES.map((p, i) => (
            <span key={p} style={{ display: 'contents' }}>
              <div className={`arwb-wf-step ${i < phase ? 'done' : i === phase ? 'current' : ''}`}>
                <div className="arwb-wf-bubble">{i < phase ? '✓' : i + 1}</div>
                <div className="arwb-wf-label">{p}{i === 2 && c.WorkflowStatus === 'QA Rejected' ? ' (rejected)' : ''}</div>
              </div>
              {i < PHASES.length - 1 && <div className={`arwb-wf-connector ${i < phase ? 'done' : ''}`} />}
            </span>
          ))}
        </div>
        {detail.workflowStages.length > 0 && (
          <div className="arwb-hint" style={{ marginTop: 8 }}>
            Workflow path for <b>{detail.workflowTemplateLabel}</b>: {detail.workflowStages.map((s) => s.stageName).join(' → ')}
          </div>
        )}
      </div>

      <div className="arwb-panel">
        <div className="arwb-tabs arwb-tabs-flush" role="tablist">
          {tabs.map(([id, label]) => (
            <button key={id} type="button" role="tab" aria-selected={tab === id} className={`arwb-tab-btn ${tab === id ? 'active' : ''}`} onClick={() => setTab(id)}>{label}</button>
          ))}
        </div>
        <div className="arwb-tab-panel">
          {tab === 'overview' && <Overview c={c} />}
          {tab === 'cpt' && <Cpt lines={detail.lines} />}
          {tab === 'denial' && <Denial c={c} followUps={detail.followUps} codes={detail.denialCodeInfo || []} />}
          {tab === 'followups' && <FollowUps c={c} rows={detail.followUps} />}
          {tab === 'activity' && <Activity rows={detail.activity} />}
          {tab === 'requests' && <AgentRequests rows={detail.agentRequests || []} />}
          {tab === 'cip' && <CipCases cases={detail.cipCases || []} canManage={can('approve')} labId={labId} />}
          {tab === 'qa' && detail.qaReview && (
            <QaTab review={detail.qaReview} c={c} latest={detail.followUps[0]} canDecide={can('qaDecide')} userName={user?.userName}
              onDecide={(decision) => setDialog(`qa-${decision}`)} />
          )}
        </div>
      </div>

      {(dialog === 'escalate' || dialog === 'reassignment') && (
        <AgentRequestModal claim={c} kind={dialog === 'escalate' ? 'escalation' : 'reassignment'} onClose={() => setDialog(null)}
          onDone={(message) => done(message, 'requests')} />
      )}
      {dialog === 'followup' && (
        <FollowUpModal claim={c} lastFollowUp={detail.followUps[0]} onClose={() => setDialog(null)}
          suggestedRootCause={(detail.denialCodeInfo || []).find((r) => r.denialCode === c.PrimaryDenialCode)?.actionCategory}
          onDone={(r) => done(r?.message || 'Follow-up logged and sent to QA.', 'followups')} />
      )}
      {(dialog === 'qa-approve' || dialog === 'qa-reject') && (
        <QaDecisionModal decision={dialog === 'qa-approve' ? 'approve' : 'reject'} onClose={() => setDialog(null)}
          row={{ claimKey: c.ClaimKey, claimID: c.ClaimID, isEscalation: detail.qaReview?.isEscalation, isWriteOff: detail.qaReview?.isWriteOff,
            fixResolution: detail.followUps[0]?.fixResolution, followUpComment: detail.followUps[0]?.followUpComment }}
          onDone={(r) => done(r?.message || 'Saved.', 'qa')} />
      )}
      {dialog === 'autoadjust' && (
        <AutoAdjustModal labId={labId} claimKeys={[c.ClaimKey]} onClose={() => setDialog(null)}
          onDone={(r) => done(r?.message || 'Adjusted.', 'activity')} />
      )}
      {dialog === 'assign' && (
        <AssignModal labId={labId} claimKeys={[c.ClaimKey]} excludeAgent={c.AssignedAgentUser || undefined}
          onClose={() => setDialog(null)} onDone={(r) => done(r?.message || 'Assigned.')} />
      )}
    </>
  );
}

function Stat({ label, children, className = 'mono' }) {
  return (
    <div className="arwb-stat-cell">
      <div className="s-label">{label}</div>
      <div className={`s-value ${className}`}>{children}</div>
    </div>
  );
}

function PaymentBar({ parts }) {
  const total = Math.max(1, parts.reduce((sum, p) => sum + Math.max(0, Number(p.value) || 0), 0));
  return (
    <>
      <div className="arwb-payment-bar">
        {parts.map((p) => <span key={p.label} style={{ width: `${(Math.max(0, Number(p.value) || 0) / total) * 100}%`, background: p.color }} />)}
      </div>
      <div className="arwb-payment-legend">
        {parts.map((p) => (
          <span key={p.label}><span className="arwb-lg-sw" style={{ background: p.color }} />{p.label}: <b className="mono">{fmt.money(p.value)}</b></span>
        ))}
      </div>
    </>
  );
}

// Mockup renderOverview: the 12-cell stat strip, then Payment Breakdown.
function Overview({ c }) {
  const variance = Number(c.PaymentVariance);
  return (
    <div className="arwb-stack">
      <div className="arwb-stat-strip" style={{ marginBottom: 0 }}>
        <Stat label="Billed">{fmt.money(c.ChargeAmount)}</Stat>
        <Stat label="Allowed">{fmt.money(c.AllowedAmount)}</Stat>
        <Stat label="Insurance Payment">{fmt.money(c.InsurancePayment)}</Stat>
        <Stat label="Patient Payment">{fmt.money(c.PatientPayment)}</Stat>
        <Stat label="Adjustments">{fmt.money(c.AdjustmentAmount)}</Stat>
        <Stat label="Insurance Balance" className="mono text-critical">{fmt.money(c.RemainingAR)}</Stat>
        <Stat label="Patient Balance">{fmt.money(c.PatientBalance)}</Stat>
        <Stat label="Revenue Expectation">{fmt.money(c.RevenueExpectation)}</Stat>
        <Stat label="Actual Payment">{fmt.money(c.ActualPayment)}</Stat>
        <Stat label="Variance" className={`mono ${c.PaymentVariance == null ? '' : variance > 0 ? 'text-critical' : 'text-good'}`}>{fmt.money(c.PaymentVariance)}</Stat>
        <Stat label="Potential Recovery">{fmt.money(c.PotentialRecovery)}</Stat>
        <Stat label="Recovery Status" className="">
          <span style={{ fontSize: 12.5, display: 'inline-block', marginTop: 3 }}>
            {c.RecoveryStatus ? <Badge className={RECOVERY_BADGE[c.RecoveryStatus]}>{c.RecoveryStatus}</Badge> : '—'}
          </span>
        </Stat>
      </div>

      <div className="arwb-card">
        <h3 style={{ marginBottom: 10, fontSize: 18 }}>Payment Breakdown</h3>
        <PaymentBar parts={[
          { label: 'Insurance Paid', value: c.InsurancePayment, color: 'var(--good)' },
          { label: 'Patient Paid', value: c.PatientPayment, color: 'var(--info)' },
          { label: 'Adjustments', value: c.AdjustmentAmount, color: 'var(--purple)' },
          { label: 'Outstanding Balance', value: c.RemainingAR, color: 'var(--warning)' }
        ]} />
      </div>

      {Number(c.UnderpaymentAmount) > 0 && (
        <div className="arwb-section-note">
          <Icon name="warn" size={14} /> Underpayment of <b>{fmt.money(c.UnderpaymentAmount)}</b> identified vs. expected allowable. {c.IsAppealRequired ? 'Appeal recommended.' : ''}
        </div>
      )}
      {c.IsRevenueRateMissing && (
        <div className="arwb-section-note">Revenue Expectation counts $0 for CPT lines with no fee-schedule rate loaded.</div>
      )}
    </div>
  );
}

// Mockup renderCpt: the CPT table, with the line's denial shown on a "↳" row beneath it. ICD Code,
// Units and Modifier come from the line's dbo.LineLevelData row (the API reads them live).
function Cpt({ lines }) {
  const { rows, th } = useTableSort(lines, {
    line: (l) => l.lineNumber, cpt: (l) => l.cptCode, icd: (l) => l.icdCode, units: (l) => (l.units == null ? null : Number(l.units)),
    modifier: (l) => l.modifier, billed: (l) => l.chargeAmount, allowed: (l) => l.allowedAmount, paid: (l) => l.insurancePayment,
    adjusted: (l) => l.insuranceAdjustments, balance: (l) => l.insuranceBalance, status: (l) => l.payStatus || l.lineClaimStatus,
    denial: (l) => l.denialCode
  }, { key: 'line', desc: false });
  if (!lines.length) return <div className="arwb-empty-state"><Icon name="search" /><div>No line-level rows were found for this claim.</div></div>;
  return (
    <div className="arwb-table-wrap">
      <table className="arwb-data-table">
        <thead>
          <tr>
            {th('line', '#', { className: 'num' })}{th('cpt', 'CPT')}{th('icd', 'ICD Code')}{th('units', 'Units', { className: 'num' })}{th('modifier', 'Modifier')}
            {th('billed', 'Billed', { className: 'num' })}{th('allowed', 'Allowed', { className: 'num' })}{th('paid', 'Paid', { className: 'num' })}
            {th('adjusted', 'Adjusted', { className: 'num' })}{th('balance', 'Balance', { className: 'num' })}{th('status', 'Status')}
          </tr>
        </thead>
        <tbody>
          {rows.map((l) => {
            const status = l.payStatus || l.lineClaimStatus;
            return [
              <tr key={l.lineNumber}>
                <td className="num arwb-hint">{l.lineNumber}</td>
                <td className="mono">{l.cptCode || '—'}</td>
                <td className="wrap mono">{l.icdCode || '—'}</td>
                <td className="num">{l.units ?? '—'}</td>
                <td className="mono">{l.modifier || '—'}</td>
                <td className="num mono">{fmt.money(l.chargeAmount)}</td>
                <td className="num mono">{fmt.money(l.allowedAmount)}</td>
                <td className="num mono">{fmt.money(l.insurancePayment)}</td>
                <td className="num mono">{fmt.money(l.insuranceAdjustments)}</td>
                <td className="num mono">{fmt.money(l.insuranceBalance)}</td>
                <td>{status ? <Badge className={lineStatusBadge(status)}>{status}</Badge> : '—'}</td>
              </tr>,
              l.denialCode && (
                <tr key={`${l.lineNumber}-d`} className="arwb-cpt-sub">
                  <td />
                  <td colSpan={10} className="arwb-hint wrap">↳ Denial <span className="mono">{l.denialCode}</span>{l.denialDate ? ` · ${fmt.date(l.denialDate)}` : ''}</td>
                </tr>
              )
            ];
          })}
        </tbody>
      </table>
    </div>
  );
}

// The claim's escalation & reassignment requests, newest first, with the lead's response.
function AgentRequests({ rows: all }) {
  const { rows, th } = useTableSort(all, {
    requested: (r) => r.requestedOn, type: (r) => r.requestType, reason: (r) => r.reasonCategory, by: (r) => r.requestedByName,
    status: (r) => r.requestStatus, response: (r) => r.resolvedOn
  });
  return (
    <div className="arwb-table-wrap">
      <table className="arwb-data-table">
        <thead>
          <tr>{th('requested', 'Requested')}{th('type', 'Type')}{th('reason', 'Reason / Note')}{th('by', 'Requested By')}{th('status', 'Status')}{th('response', 'Response')}</tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.agentRequestId}>
              <td>{fmt.dateTime(r.requestedOn)}</td>
              <td><Badge className={r.requestType === 'Escalation to Supervisor' ? 'arwb-badge-critical' : 'arwb-badge-info'} dot>{r.requestType}</Badge></td>
              <td className="wrap"><b>{r.reasonCategory}</b><div className="arwb-pre-line" style={{ minWidth: 0 }}>{r.requestNote}</div></td>
              <td>{r.requestedByName}</td>
              <td><Badge className={r.requestStatus === 'Pending' ? 'arwb-badge-warning' : 'arwb-badge-good'}>{r.requestStatus}</Badge></td>
              <td className="wrap">
                {r.requestStatus === 'Resolved'
                  ? <><div className="arwb-pre-line" style={{ minWidth: 0 }}>{r.resolutionNote || '—'}</div><div className="arwb-hint">{r.resolvedByName} · {fmt.dateTime(r.resolvedOn)}</div></>
                  : <span className="text-muted-ink">Awaiting response</span>}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// The fields an AR caller reads out to the payer, from dbo.LineLevelData (the API falls back to the
// synced claim values). Shown in the header so they are on screen whichever tab is open.
function PatientStrip({ patient, claim }) {
  const p = patient || {};
  const fields = [
    ['Payer', claim.PayerName],
    ['Panel', claim.PanelName],
    ['DOS', claim.DateOfService ? fmt.date(claim.DateOfService) : null],
    ['Patient Name', p.patientName ?? claim.PatientName],
    ['Patient DOB', p.patientDOB ? fmt.date(p.patientDOB) : null],
    ['Patient ID', p.patientID ?? claim.PatientID, true],
    ['Subscriber ID', p.subscriberID, true],
    ['Referring Provider', p.referringProvider ?? claim.ReferringProvider],
    ['Facility', p.facility],
    ['Ordering Clinic', claim.ClinicName]
  ];
  return (
    <div className="arwb-patient-strip" aria-label="Patient and provider">
      {fields.map(([label, value, mono]) => (
        <div key={label} className="arwb-patient-field">
          <span className="arwb-patient-label">{label}</span>
          <span className={`arwb-patient-value${mono ? ' mono' : ''}`}>{value || '—'}</span>
        </div>
      ))}
    </div>
  );
}

function DetailSection({ title, hint, children }) {
  return (
    <section className="arwb-detail-section">
      <div className="arwb-detail-section-head">{title}{hint && <span className="arwb-hint">{hint}</span>}</div>
      <dl className="arwb-dl-rows">{children}</dl>
    </section>
  );
}

function Row({ label, children }) {
  return (
    <div className="arwb-dl-row">
      <dt>{label}</dt>
      <dd>{children ?? '—'}</dd>
    </div>
  );
}

// Denial Info: the mockup's fields, as two titled sections with aligned label / value rows.
// Mockup renderCipCases: each CIP escalation with its full history, read-only; decisions are made
// in the CIP Escalations queue so the action and its context stay in one place.
function CipCases({ cases, canManage, labId }) {
  const badge = { 'Awaiting QA': 'arwb-badge-neutral', 'Pending Approval': 'arwb-badge-warning', 'Sent to Client': 'arwb-badge-info', 'Client Responded': 'arwb-badge-purple', 'Returned to Agent': 'arwb-badge-good' };
  return (
    <div className="arwb-stack">
      {cases.map(({ case: cc, history }) => (
        <div key={cc.cipCaseId} className="arwb-followup-item">
          <div className="fu-top">
            <span><b className="mono">{cc.caseNumber}</b> · <Badge className={badge[cc.caseStatus]}>{cc.caseStatus}{cc.roundNumber > 1 ? ` · Round ${cc.roundNumber}` : ''}</Badge></span>
            <span className="arwb-hint">requested by {cc.requestedBy} · {fmt.date(cc.requestedOn)}</span>
          </div>
          <div className="fu-notes"><b>{cc.cipCategory}</b> · {cc.requiredInfo}<div>{cc.cipComment}</div></div>
          {cc.clientResponseText && <div className="fu-notes"><b>Client response</b> ({cc.clientRespondedBy} · {fmt.dateTime(cc.clientRespondedOn)}): {cc.clientResponseText}</div>}
          {cc.attachments?.length > 0 && <div className="fu-notes"><b>Attachments</b> <Attachments labId={labId} files={cc.attachments} /></div>}
          <div className="arwb-timeline" style={{ marginTop: 8 }}>
            {history.map((h, i) => (
              <div key={i} className="arwb-hint">
                {fmt.dateTime(h.actionOn)} · <b>{h.actionName}</b>{h.roundNumber > 1 ? ` (round ${h.roundNumber})` : ''} · {h.actor}{h.isBulkAction ? ' · bulk' : ''}{h.note ? ` — ${h.note}` : ''}
              </div>
            ))}
          </div>
          {canManage && (cc.caseStatus === 'Pending Approval' || cc.caseStatus === 'Client Responded') && (
            <Link to="/cip" className="arwb-btn arwb-btn-sm" style={{ marginTop: 8, textDecoration: 'none' }}>Manage in CIP Escalations</Link>
          )}
        </div>
      ))}
    </div>
  );
}

// Mockup renderQa: the claim's current QA review, with Approve / Reject for a reviewer who did not
// write the note and does not hold the claim.
function QaTab({ review, c, latest, canDecide, userName, onDecide }) {
  const own = userName && (review.submittedBy?.toLowerCase() === userName.toLowerCase() || c.AssignedAgentUser?.toLowerCase() === userName.toLowerCase());
  const badge = { 'Awaiting QA': 'arwb-badge-purple', Approved: 'arwb-badge-good', Rejected: 'arwb-badge-critical' }[review.reviewStatus];
  return (
    <>
      <div className="arwb-grid-2">
        <DetailSection title="QA Review">
          <Row label="QA Status"><Badge className={badge}>{review.reviewStatus}</Badge>{review.isEscalation && <> <Badge className="arwb-badge-purple" dot>CIP Escalation</Badge></>}{review.isWriteOff && <> <Badge className="arwb-badge-warning">Write Off</Badge></>}</Row>
          <Row label="Submitted">{`${review.submittedBy} · ${fmt.dateTime(review.submittedOn)}`}</Row>
          <Row label="Reviewer">{review.reviewedBy ? `${review.reviewedBy} · ${fmt.dateTime(review.reviewedOn)}` : <span className="text-muted-ink">Unassigned</span>}</Row>
          <Row label="Error Type">{review.errorType || (review.reviewStatus === 'Approved' ? 'None' : null)}</Row>
          <Row label="Notes">{review.reviewNote}</Row>
          <Row label="Note under review">{latest ? `${latest.fixResolution} · ${latest.followUpClaimStatus}${latest.followUpComment ? ` — ${latest.followUpComment}` : ''}` : null}</Row>
        </DetailSection>
        <DetailSection title="Quality Scoring Criteria" hint={review.reviewStatus === 'Awaiting QA' ? 'Scored when QA decides' : null}>
          {review.reviewStatus !== 'Awaiting QA' && QA_CRITERIA.map(([k, label]) => {
            const v = review.scores?.[k];
            return (
              <div key={k} className="arwb-qa-score">
                <span className={v === true ? 'text-good' : v === false ? 'text-critical' : 'text-muted-ink'}>{v === true ? '✓' : v === false ? '✕' : '–'}</span> {label}
              </div>
            );
          })}
        </DetailSection>
      </div>
      {canDecide && review.reviewStatus === 'Awaiting QA' && (
        <div className="arwb-flex-row" style={{ marginTop: 16, gap: 8, display: 'flex', alignItems: 'center' }}>
          {own
            ? <span className="arwb-hint">Business rule: you cannot QA your own work — another reviewer must decide this note.</span>
            : (
              <>
                <button type="button" className="arwb-btn arwb-btn-primary" onClick={() => onDecide('approve')}><Icon name="check" size={15} /> Approve</button>
                <button type="button" className="arwb-btn arwb-btn-danger" onClick={() => onDecide('reject')}>Reject / Return for Correction</button>
              </>
            )}
        </div>
      )}
    </>
  );
}

// The central Denial Code Master (Master Values > Denial Code Descriptions) for every code on the
// claim, primary first. Codes are without their group prefix (CO-4 and PR4 are both 4).
function DenialCodeMaster({ codes, primary, lineCodes }) {
  const order = [primary, ...lineCodes].filter(Boolean);
  const byCode = Object.fromEntries(codes.map((r) => [r.denialCode, r]));
  const listed = [...new Set(order)];
  const missing = listed.filter((code) => !byCode[code]);
  return (
    <DetailSection title="Denial Code Master" hint={listed.length ? null : 'No denial codes on this claim'}>
      {listed.filter((code) => byCode[code]).map((code) => {
        const r = byCode[code];
        return (
          <div key={code} className="arwb-code-info">
            <div className="arwb-code-info-head">
              <span className={`arwb-code-chip${code === primary ? ' primary' : ''}`}>{code}</span>
              {code === primary && <span className="arwb-hint">primary</span>}
              {r.isNonCollectible && <Badge className="arwb-badge-critical">Non-Collectible</Badge>}
              <span className="grow">{r.denialDescription || <span className="text-muted-ink">No description</span>}</span>
            </div>
            <div className="arwb-code-info-grid">
              <span>Action Category</span><b>{r.actionCategory || '—'}</b>
              <span>Classification</span><b>{r.denialClassification || '—'}</b>
              <span>Coverage Status</span><b>{r.coverageStatus || '—'}</b>
              <span>ICD Compliance</span><b>{r.icdComplianceStatus || '—'}</b>
              <span>Denial Validity</span><b>{r.denialValidity || '—'}</b>
            </div>
          </div>
        );
      })}
      {missing.length > 0 && (
        <div className="arwb-hint">Not in the Denial Code master: {missing.map((code) => <span key={code} className="arwb-code-chip">{code}</span>)}</div>
      )}
    </DetailSection>
  );
}

function Denial({ c, followUps, codes }) {
  const latest = followUps[0];
  const lineCodes = (c.LineDenialCodes || '').split(',').map((s) => s.trim()).filter(Boolean);
  const primary = c.PrimaryDenialCode;
  return (
    <>
    <div className="arwb-grid-2">
      <DetailSection title="Denial" hint={c.DenialCategory ? null : 'No denial on this claim'}>
        <Row label="Denial Category">{c.DenialCategory ? <Badge className="arwb-badge-accent">{c.DenialCategory}</Badge> : null}</Row>
        <Row label="Primary Denial Code">{c.PrimaryDenialCodeRaw || c.DenialCode ? <span className="arwb-code-chip primary">{c.PrimaryDenialCodeRaw || c.DenialCode}</span> : null}</Row>
        <Row label="Denial Reason">{c.DenialReason}</Row>
        <Row label="Denial Date">{c.DenialDate ? fmt.date(c.DenialDate) : null}</Row>
        <Row label="Line-Level Codes">
          {lineCodes.length ? lineCodes.map((code) => <span key={code} className={`arwb-code-chip${code === primary ? ' primary' : ''}`}>{code}</span>) : null}
        </Row>
        <Row label="Claim Status (source)">{c.SourceClaimStatus}</Row>
      </DetailSection>

      <DetailSection title="Resolution">
        <Row label="AR Queue">
          <Badge className={arQueueBadgeClass(c.ArQueueId)}>{c.ArSubQueueLabel || c.ArQueueLabel}</Badge>
          {c.ArSubQueueLabel && <span className="arwb-hint"> {c.ArQueueLabel}</span>}
        </Row>
        <Row label="Corrective Action">{c.DenialCategory ? (CORRECTIVE_ACTION[c.DenialCategory] || CORRECTIVE_ACTION.Other) : null}</Row>
        <Row label="Appeal Deadline (TFL)">
          {c.TflDeadline ? <span className={c.IsTflRisk ? 'text-critical' : ''}>{fmt.date(c.TflDeadline)}{c.IsTflRisk && <> <Badge className="arwb-badge-critical" dot>At Risk</Badge></>}</span> : null}
        </Row>
        <Row label="Supporting Docs Required">{c.DenialCategory === 'Additional Documentation Required' ? <Badge className="arwb-badge-warning">Yes</Badge> : 'Not indicated'}</Row>
        <Row label="Latest Follow-Up">{latest ? `${latest.fixResolution} · ${latest.followUpClaimStatus}` : <span className="text-muted-ink">No follow-up logged yet</span>}</Row>
        <Row label="Non-Collectible">
          {c.IsNonCollectible ? <><Badge className="arwb-badge-critical">Yes</Badge> <span className="arwb-hint">primary code — Non-Collectible queue</span></>
            : c.HasNonCollectibleDenial ? <><Badge className="arwb-badge-critical">Yes</Badge> <span className="arwb-hint">a line-level code</span></>
              : 'No'}
        </Row>
      </DetailSection>
    </div>
    <div style={{ marginTop: 16 }}>
      <DenialCodeMaster codes={codes} primary={primary} lineCodes={lineCodes} />
    </div>
    </>
  );
}

// Mockup renderFollowUps.
function FollowUps({ c, rows }) {
  return (
    <>
      <div className="arwb-flex-between" style={{ marginBottom: 12 }}>
        <div className="arwb-hint">
          AR Queue: <QueueBadge queueId={c.ArQueueId} label={c.ArQueueLabel} subLabel={c.ArSubQueueLabel} /> · Next follow-up: <b>{c.NextFollowUpDate ? fmt.date(c.NextFollowUpDate) : 'Not scheduled'}</b>
        </div>
      </div>
      <div className="arwb-stack">
        {rows.length ? rows.map((f) => (
          <div key={f.followUpId} className="arwb-followup-item">
            <div className="fu-top">
              <span>{f.followUpType} · {f.claimType} · <Badge className="arwb-badge-info">{f.fixResolution}</Badge></span>
              <span className="arwb-hint">{fmt.date(f.createdOn)}</span>
            </div>
            {f.followUpComment && <div className="fu-notes">{f.followUpComment}</div>}
            <div className="fu-meta">Claim Status: {f.followUpClaimStatus}{f.denialRootCause ? ` · Root Cause: ${f.denialRootCause}` : ''}</div>
            <div className="fu-meta">Logged by {f.createdBy}{f.nextFollowUpDate ? ` · Next: ${fmt.date(f.nextFollowUpDate)}` : ''}</div>
          </div>
        )) : (
          <div className="arwb-empty-state"><Icon name="phone" /><div>No follow-up notes logged yet.</div></div>
        )}
      </div>
      <div className="arwb-hint" style={{ marginTop: 8 }}>Assigned agent: <AgentName name={c.AssignedAgentName || c.AssignedAgentUser} /></div>
    </>
  );
}

// Mockup renderActivity: the timeline.
function Activity({ rows }) {
  if (!rows.length) return <div className="arwb-empty-state">No activity yet.</div>;
  return (
    <div className="arwb-tl">
      {rows.map((a) => (
        <div key={a.activityId} className="arwb-tl-item">
          <div className="arwb-tl-time">{fmt.dateTime(a.activityOn)}</div>
          <div className="arwb-tl-dot" />
          <div>
            <div className="arwb-tl-action">{a.actionType}</div>
            <div className="arwb-tl-desc">{a.detail || ''}</div>
            <div className="arwb-tl-user">{a.isSystem ? 'System · Automation' : `${a.userName}${a.roleCode ? ` · ${a.roleCode}` : ''}`}</div>
          </div>
        </div>
      ))}
    </div>
  );
}
