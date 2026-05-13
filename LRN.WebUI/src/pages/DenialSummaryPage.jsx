import React, { useMemo } from 'react';
import { money } from '../utils/formatters';

function getBilled(row) {
  return Number(row.billed ?? row.billedAmount ?? row.totalBilled ?? row.charges ?? row.outstanding ?? 0);
}

function getInsBalance(row) {
  return Number(row.insuranceBalance ?? row.insBalance ?? row.outstanding ?? 0);
}

function SummaryProgress({ value, max }) {
  const width = max > 0 ? Math.min(100, Math.max(3, (Number(value || 0) / max) * 100)) : 0;
  return <span className="summary-mini-progress"><span style={{ width: `${width}%` }} /></span>;
}

export default function DenialSummaryPage({ data, onClassificationClick, onActionCategoryClick }) {
  const classifications = data.denialClassifications || [];
  const actions = data.actionCategories || [];

  const classTotals = useMemo(() => ({
    claims: classifications.reduce((s, r) => s + Number(r.count || 0), 0),
    billed: classifications.reduce((s, r) => s + getBilled(r), 0),
    ins: classifications.reduce((s, r) => s + getInsBalance(r), 0),
    maxIns: Math.max(0, ...classifications.map(getInsBalance))
  }), [classifications]);

  const actionTotals = useMemo(() => ({
    claims: actions.reduce((s, r) => s + Number(r.count || 0), 0),
    billed: actions.reduce((s, r) => s + getBilled(r), 0),
    ins: actions.reduce((s, r) => s + getInsBalance(r), 0),
    maxIns: Math.max(0, ...actions.map(getInsBalance))
  }), [actions]);

  return (
    <div className="row-2 summary-style-grid">
      <div className="summary-style-card">
        <div className="summary-style-title">Denial classification summary</div>
        <div className="summary-style-table-wrap">
          <div className="summary-style-hint">Click a classification to view and assign claims</div>
          <table className="summary-style-table">
            <thead>
              <tr>
                <th>Classification</th>
                <th className="num">Claims</th>
                <th className="num">Billed</th>
                <th className="num">Ins. Balance</th>
              </tr>
            </thead>
            <tbody>
              {classifications.length ? classifications.map((r, i) => {
                const ins = getInsBalance(r);
                return (
                  <tr key={`${r.classification}-${i}`}>
                    <td>
                      <button className="summary-link-text" type="button" onClick={() => onClassificationClick?.(r.classification || '')}>
                        {r.classification || 'Unclassified'}
                      </button>
                    </td>
                    <td className="num">{Number(r.count || 0).toLocaleString()}</td>
                    <td className="num">{money(getBilled(r))}</td>
                    <td className="num ins-cell"><span>{money(ins)}</span><SummaryProgress value={ins} max={classTotals.maxIns} /></td>
                  </tr>
                );
              }) : <tr><td colSpan="4" className="empty-cell">No denial classification summary found.</td></tr>}
              {classifications.length > 0 && (
                <tr className="summary-total-row">
                  <td>Total</td>
                  <td className="num">{classTotals.claims.toLocaleString()}</td>
                  <td className="num">{money(classTotals.billed)}</td>
                  <td className="num total-balance">{money(classTotals.ins)}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      <div className="summary-style-card">
        <div className="summary-style-title">Action / task summary</div>
        <div className="summary-style-table-wrap">
          <div className="summary-style-hint">Click an action/task to view and assign claims</div>
          <table className="summary-style-table">
            <thead>
              <tr>
                <th>Action / Task</th>
                <th className="num">Claims</th>
                <th className="num">Billed</th>
                <th className="num">Ins. Balance</th>
              </tr>
            </thead>
            <tbody>
              {actions.length ? actions.map((r, i) => {
                const ins = getInsBalance(r);
                return (
                  <tr key={`${r.actionCategory}-${i}`}>
                    <td>
                      <button className="summary-link-text" type="button" onClick={() => onActionCategoryClick?.(r.actionCategory || '')}>
                        {r.actionCategory || 'Unclassified'}
                      </button>
                    </td>
                    <td className="num">{Number(r.count || 0).toLocaleString()}</td>
                    <td className="num">{money(getBilled(r))}</td>
                    <td className="num ins-cell"><span>{money(ins)}</span><SummaryProgress value={ins} max={actionTotals.maxIns} /></td>
                  </tr>
                );
              }) : <tr><td colSpan="4" className="empty-cell">No action/task summary found.</td></tr>}
              {actions.length > 0 && (
                <tr className="summary-total-row">
                  <td>Total</td>
                  <td className="num">{actionTotals.claims.toLocaleString()}</td>
                  <td className="num">{money(actionTotals.billed)}</td>
                  <td className="num total-balance">{money(actionTotals.ins)}</td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
