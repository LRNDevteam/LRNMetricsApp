import React from 'react';

export default function WorkflowTable({ columns = [], rows = [], rowKey, emptyText = 'No claims found for the selected filters.', onRowClick }) {
  return <div className="workflow-table-shell">
    <table className="lrn-table workflow-table modern-workflow-table">
      <thead>
        <tr>{columns.map(col => <th key={col.key || col.header} className={col.className || ''}>{col.header}</th>)}</tr>
      </thead>
      <tbody>
        {rows.length ? rows.map((row, index) => (
          <tr key={rowKey ? rowKey(row, index) : index} onClick={onRowClick ? () => onRowClick(row, index) : undefined}>
            {columns.map(col => <td key={col.key || col.header} className={col.cellClassName || col.className || ''}>{col.render ? col.render(row, index) : row[col.key]}</td>)}
          </tr>
        )) : <tr><td colSpan={columns.length || 1} className="empty-cell">{emptyText}</td></tr>}
      </tbody>
    </table>
  </div>;
}
