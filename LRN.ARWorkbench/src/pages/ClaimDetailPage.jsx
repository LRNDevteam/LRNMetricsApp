import { useEffect, useState } from 'react';
import { Link, useLocation, useParams } from 'react-router';
import { ErrorBox, Loading, QueueBadge, StatusBadge } from '../components/Status';
import { useWorkbench } from '../context/WorkbenchContext';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt, priorityBadgeClass } from '../utils/format';

// The claim record arrives as a dictionary of arwb.vw_ClaimWorklist columns (PascalCase keys).
const STEPS = ['Identified', 'Assigned', 'QA Verification', 'Completed'];
const STEP_OF_STATUS = { Unassigned: 0, Assigned: 1, 'Submitted for QA': 2, 'QA Rejected': 2, Completed: 3 };

function Field({ label, children }) {
  return (
    <div className="col-6 col-md-4 col-xl-3">
      <div className="arwb-field-label">{label}</div>
      <div className="arwb-field-value">{children ?? '—'}</div>
    </div>
  );
}

function Stepper({ status }) {
  const current = STEP_OF_STATUS[status] ?? 0;
  return (
    <ol className="arwb-stepper">
      {STEPS.map((s, i) => (
        <li key={s} className={i < current ? 'done' : i === current ? 'current' : ''}>
          <span className="arwb-step-dot">{i < current ? <i className="bi bi-check" /> : i + 1}</span>
          <span className="arwb-step-label">{s}{i === 2 && status === 'QA Rejected' ? ' (rejected)' : ''}</span>
        </li>
      ))}
    </ol>
  );
}

export default function ClaimDetailPage() {
  const { claimKey } = useParams();
  const location = useLocation();
  const { labId } = useWorkbench();
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

  if (error) return <><BackLink to={backTo} /><ErrorBox message={error} /></>;
  if (!detail) return <Loading />;

  const c = detail.claim;
  const tabs = [
    ['overview', 'Overview'],
    ['lines', `CPT / Line Detail (${detail.lines.length})`],
    ['denial', 'Denial Info'],
    ['followups', `Follow-Ups (${detail.followUps.length})`],
    ['activity', 'Activity Timeline']
  ];

  return (
    <>
      <BackLink to={backTo} />

      <div className="arwb-claim-header">
        <div className="d-flex flex-wrap align-items-center gap-2 mb-2">
          <h1 className="h4 mb-0 me-2">{c.ClaimID}</h1>
          <StatusBadge status={c.WorkflowStatus} />
          <QueueBadge label={c.ArQueueLabel} subLabel={c.ArSubQueueLabel} badge={c.ArQueueBadgeClass} />
          {c.Priority && <span className={`badge ${priorityBadgeClass(c.Priority)}`}>{c.Priority} priority</span>}
          {c.IsTflRisk && <span className="badge text-bg-danger">TFL at risk · {fmt.date(c.TflDeadline)}</span>}
          {c.IsNonCollectible && <span className="badge text-bg-secondary">Non-collectible</span>}
          {c.PendingAgentRequests > 0 && <span className="badge text-bg-info">Pending agent request</span>}
          {!c.IsInCurrentSource && <span className="badge text-bg-light border">Not in latest source file</span>}
        </div>
        <div className="text-secondary small">
          {[c.LabName, c.PayerName, c.PanelName, `DOS ${fmt.date(c.DateOfService)}`, c.PatientID && `Patient ${c.PatientID}`, c.ReferringProvider, c.ClinicName]
            .filter(Boolean).join(' · ')}
        </div>
      </div>

      <div className="arwb-card mb-3">
        <Stepper status={c.WorkflowStatus} />
        {detail.workflowStages.length > 0 && (
          <div className="arwb-stage-path">
            <span className="text-secondary small me-2">{detail.workflowTemplateLabel}:</span>
            {detail.workflowStages.map((s, i) => (
              <span key={s.stageOrder} className="small">
                {s.stageName}{i < detail.workflowStages.length - 1 && <i className="bi bi-chevron-right mx-1 text-body-tertiary" />}
              </span>
            ))}
          </div>
        )}
      </div>

      <ul className="nav nav-tabs mb-3">
        {tabs.map(([id, label]) => (
          <li className="nav-item" key={id}>
            <button type="button" className={`nav-link ${tab === id ? 'active' : ''}`} onClick={() => setTab(id)}>{label}</button>
          </li>
        ))}
      </ul>

      {tab === 'overview' && <Overview c={c} />}
      {tab === 'lines' && <Lines lines={detail.lines} />}
      {tab === 'denial' && <Denial c={c} />}
      {tab === 'followups' && <FollowUps rows={detail.followUps} />}
      {tab === 'activity' && <Activity rows={detail.activity} />}
    </>
  );
}

function BackLink({ to }) {
  return <Link to={to} className="d-inline-block small mb-2"><i className="bi bi-arrow-left me-1" />Back</Link>;
}

function Overview({ c }) {
  return (
    <div className="arwb-card">
      <h2 className="h6">Recovery</h2>
      <div className="row g-3 mb-4">
        <Field label="Initial insurance AR">{fmt.money(c.InitialInsuranceAR)}</Field>
        <Field label="Recovered">{fmt.money(c.RecoveredAmount)}</Field>
        <Field label="Remaining AR">{fmt.money(c.RemainingAR)}</Field>
        <Field label="Recovery status">{c.RecoveryStatus}</Field>
        <Field label="Expected payment">{fmt.money(c.ExpectedPayment)}</Field>
        <Field label="Payment variance">{fmt.money(c.PaymentVariance)}</Field>
        <Field label="Underpayment">{fmt.money(c.UnderpaymentAmount)}</Field>
        <Field label="Appeal required">{c.IsAppealRequired ? 'Yes' : 'No'}</Field>
      </div>
      <h2 className="h6">Financials (source)</h2>
      <div className="row g-3 mb-4">
        <Field label="Billed">{fmt.money(c.ChargeAmount)}</Field>
        <Field label="Allowed">{fmt.money(c.AllowedAmount)}</Field>
        <Field label="Insurance payment">{fmt.money(c.InsurancePayment)}</Field>
        <Field label="Patient payment">{fmt.money(c.PatientPayment)}</Field>
        <Field label="Adjustments">{fmt.money(c.AdjustmentAmount)}</Field>
        <Field label="Insurance balance">{fmt.money(c.InsuranceBalance)}</Field>
        <Field label="Patient balance">{fmt.money(c.PatientBalance)}</Field>
        <Field label="Total balance">{fmt.money(c.TotalBalance)}</Field>
      </div>
      <h2 className="h6">Workflow</h2>
      <div className="row g-3">
        <Field label="Assigned agent">{c.AssignedAgentName || c.AssignedAgentUser || 'Unassigned'}</Field>
        <Field label="Last follow-up">{fmt.date(c.LastFollowUpDate)}</Field>
        <Field label="Next follow-up">{fmt.date(c.NextFollowUpDate)}</Field>
        <Field label="Fix / resolution">{c.FixResolution}</Field>
        <Field label="Aging">{c.AgingDays != null ? `${c.AgingDays} days (${c.AgingBucket})` : null}</Field>
        <Field label="Days since last touch">{c.DaysSinceLastTouch}</Field>
        <Field label="Financial class">{c.PayerType}</Field>
        <Field label="First identified">{fmt.dateTime(c.FirstIdentifiedOn)}</Field>
      </div>
    </div>
  );
}

function Lines({ lines }) {
  if (!lines.length) return <div className="arwb-card text-secondary">No line-level rows were found for this claim in dbo.LineLevelData.</div>;
  return (
    <div className="arwb-table-card">
      <div className="table-responsive">
        <table className="table table-sm align-middle mb-0 arwb-table">
          <thead>
            <tr>
              <th>#</th><th>CPT</th><th>Mod</th><th className="text-end">Units</th>
              <th className="text-end">Billed</th><th className="text-end">Allowed</th><th className="text-end">Ins. paid</th>
              <th className="text-end">Adjusted</th><th className="text-end">Ins. balance</th>
              <th>Status</th><th>Denial code</th><th>Denial date</th><th>ICD</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((l) => (
              <tr key={l.lineNumber}>
                <td>{l.lineNumber}</td>
                <td className="fw-semibold">{l.cptCode || '—'}</td>
                <td>{l.modifier || '—'}</td>
                <td className="text-end">{l.units ?? '—'}</td>
                <td className="text-end">{fmt.money(l.chargeAmount)}</td>
                <td className="text-end">{fmt.money(l.allowedAmount)}</td>
                <td className="text-end">{fmt.money(l.insurancePayment)}</td>
                <td className="text-end">{fmt.money(l.insuranceAdjustments)}</td>
                <td className="text-end fw-semibold">{fmt.money(l.insuranceBalance)}</td>
                <td>{l.payStatus || l.lineClaimStatus || '—'}</td>
                <td>{l.denialCode || '—'}</td>
                <td>{fmt.date(l.denialDate)}</td>
                <td className="small">{l.icdCode || '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Denial({ c }) {
  return (
    <div className="arwb-card">
      <div className="row g-3">
        <Field label="Denial code(s)">{c.DenialCode}</Field>
        <Field label="Denial category">{c.DenialCategory}</Field>
        <Field label="Denial date">{fmt.date(c.DenialDate)}</Field>
        <Field label="Source claim status">{c.SourceClaimStatus}</Field>
        <Field label="Root cause">{c.DenialRootCause}</Field>
        <Field label="Non-collectible">{c.IsNonCollectible ? 'Yes' : 'No'}</Field>
      </div>
      {c.DenialReason && <div className="mt-3"><div className="arwb-field-label">Denial reason</div><div>{c.DenialReason}</div></div>}
    </div>
  );
}

function FollowUps({ rows }) {
  if (!rows.length) return <div className="arwb-card text-secondary">No follow-up notes yet. Logging follow-ups arrives with phase 3.</div>;
  return (
    <div className="d-flex flex-column gap-2">
      {rows.map((f) => (
        <div key={f.followUpId} className="arwb-card">
          <div className="d-flex flex-wrap gap-2 small text-secondary mb-1">
            <span className="fw-semibold text-body">{f.createdBy}</span>
            <span>{fmt.dateTime(f.createdOn)}</span>
            <span>· {f.followUpType} · {f.claimType}</span>
          </div>
          <div className="mb-1"><strong>{f.followUpClaimStatus}</strong> → {f.fixResolution}{f.denialRootCause ? ` · ${f.denialRootCause}` : ''}</div>
          {f.followUpComment && <div className="small">{f.followUpComment}</div>}
          {f.nextFollowUpDate && <div className="small text-secondary mt-1">Next follow-up {fmt.date(f.nextFollowUpDate)}</div>}
        </div>
      ))}
    </div>
  );
}

function Activity({ rows }) {
  return (
    <ul className="arwb-timeline">
      {rows.map((a) => (
        <li key={a.activityId}>
          <div className="small text-secondary">
            {fmt.dateTime(a.activityOn)} · {a.isSystem ? <span className="badge text-bg-light border">System / Automation</span> : a.userName}
          </div>
          <div className="fw-semibold">{a.actionType}</div>
          {a.detail && <div className="small">{a.detail}</div>}
        </li>
      ))}
    </ul>
  );
}
