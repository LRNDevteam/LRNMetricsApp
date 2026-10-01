import { useEffect, useState } from 'react';
import { Link, useLocation, useParams } from 'react-router';
import Icon from '../components/Icon';
import { AgentName, Badge, ErrorBox, Loading, QueueBadge, StatusBadge } from '../components/Status';
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
  const { labId, can } = useWorkbench();
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState('');
  const [tab, setTab] = useState('overview');

  useEffect(() => {
    const controller = new AbortController();
    setDetail(null);
    setError('');
    arWorkbenchService.claim(labId, claimKey, controller.signal)
      .then(setDetail)
      .catch((e) => { if (e.name !== 'AbortError') setError(e.message); });
    return () => controller.abort();
  }, [labId, claimKey]);

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
    ['activity', 'Activity Timeline']
  ];

  return (
    <>
      {back}

      <div className="arwb-card arwb-section">
        <div className="arwb-claim-head" style={{ marginBottom: 0 }}>
          <div className="ident">
            <div className="arwb-claim-id-big">{c.ClaimID}</div>
            <div className="arwb-meta-row">
              <StatusBadge status={c.WorkflowStatus} />
              <Badge className={arQueueBadgeClass(c.ArQueueId)}>{c.ArSubQueueLabel || c.ArQueueLabel}</Badge>
              {c.Priority && <span className={`priority-${c.Priority}`}>● {c.Priority} priority</span>}
              {c.IsTflRisk && <Badge className="arwb-badge-critical" dot>TFL At Risk</Badge>}
              {c.PendingAgentRequests > 0 && <Badge className="arwb-badge-warning" dot>Request — Pending</Badge>}
              {!c.IsInCurrentSource && <Badge>Not in latest source file</Badge>}
              <span className="text-muted-ink">{c.LabName}</span>·<span className="text-muted-ink">{c.PayerName || '—'}</span>·<span className="text-muted-ink">{c.PanelName || '—'}</span>· DOS {fmt.date(c.DateOfService)}
            </div>
            <div className="arwb-meta-row arwb-hint">
              Patient Acct <b className="mono">{c.PatientID || '—'}</b>
              {c.ReferringProvider && <> · Rendering: {c.ReferringProvider}</>}
              {c.ClinicName && <> · Ordering: {c.ClinicName}</>}
            </div>
          </div>
          <div className="arwb-claim-actions">
            {can('assign') && <button type="button" className="arwb-btn arwb-btn-sm" disabled title="Assignment arrives with phase 3">{agent ? 'Reassign' : 'Assign'}</button>}
            {can('editClaim') && c.WorkflowStatus !== 'Submitted for QA' && !c.IsFinanciallyClosed && (
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-primary" disabled title="Logging follow-ups arrives with phase 3">Log Follow-Up Note</button>
            )}
          </div>
        </div>
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
          {tab === 'denial' && <Denial c={c} followUps={detail.followUps} />}
          {tab === 'followups' && <FollowUps c={c} rows={detail.followUps} />}
          {tab === 'activity' && <Activity rows={detail.activity} />}
        </div>
      </div>
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

// Mockup renderCpt: the CPT table, with the line's denial shown on a "↳" row beneath it.
function Cpt({ lines }) {
  if (!lines.length) return <div className="arwb-empty-state"><Icon name="search" /><div>No line-level rows were found for this claim.</div></div>;
  return (
    <div className="arwb-table-wrap">
      <table className="arwb-data-table">
        <thead>
          <tr>
            <th>CPT</th><th>Modifier</th><th>Diagnosis</th><th className="num">Units</th><th className="num">Billed</th>
            <th className="num">Allowed</th><th className="num">Paid</th><th className="num">Adjusted</th><th className="num">Balance</th><th>Status</th>
          </tr>
        </thead>
        <tbody>
          {lines.map((l) => {
            const status = l.payStatus || l.lineClaimStatus;
            return [
              <tr key={l.lineNumber}>
                <td className="mono">{l.cptCode || '—'}</td>
                <td>{l.modifier || '—'}</td>
                <td className="wrap arwb-hint">{l.icdCode || '—'}</td>
                <td className="num">{l.units ?? '—'}</td>
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
                  <td colSpan={9} className="arwb-hint wrap">↳ Denial <span className="mono">{l.denialCode}</span>{l.denialDate ? ` · ${fmt.date(l.denialDate)}` : ''}</td>
                </tr>
              )
            ];
          })}
        </tbody>
      </table>
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
function Denial({ c, followUps }) {
  const latest = followUps[0];
  const lineCodes = (c.LineDenialCodes || '').split(',').map((s) => s.trim()).filter(Boolean);
  const primary = c.PrimaryDenialCode;
  return (
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
        <Row label="Non-Collectible">{c.IsNonCollectible ? <Badge className="arwb-badge-critical">Yes</Badge> : 'No'}</Row>
      </DetailSection>
    </div>
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
