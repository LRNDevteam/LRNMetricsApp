import React from 'react';

function inferDocumentType(doc) {
  const direct = doc.documentType || doc.type || doc.DocumentType || doc.Type;
  if (direct) return direct;
  const text = `${doc.originalFileName || ''} ${doc.comment || ''}`.toLowerCase();
  if (text.includes('auth')) return 'Patient Document';
  if (text.includes('lab') || text.includes('result') || text.includes('clinical')) return 'Clinical Document';
  if (text.includes('elig') || text.includes('eob') || text.includes('verification') || text.includes('payer')) return 'Payer Response';
  return 'Supporting Document';
}

export default function DocumentTable({ documents = [], canUpload = false, canDelete = () => false, onUpload, onDownload, onDelete, formatDate }) {
  const rows = documents || [];
  const fmt = formatDate || (value => value ? new Date(value).toLocaleDateString() : '-');
  return <div className="document-view-panel">
    <div className="document-view-header">
      <h3>Documents</h3>
      {canUpload && <button className="document-upload-btn" type="button" onClick={onUpload}>Upload Document</button>}
    </div>
    <div className="document-table-wrap">
      <table className="document-table">
        <thead><tr><th>Document Name</th><th>Type</th><th>Uploaded By</th><th>Uploaded On</th><th>Action</th></tr></thead>
        <tbody>{rows.length ? rows.map(doc => <tr key={doc.documentId || doc.originalFileName}>
          <td>{doc.originalFileName || '-'}</td>
          <td>{inferDocumentType(doc)}</td>
          <td>{doc.uploadedBy || '-'}</td>
          <td>{fmt(doc.uploadedOn)}</td>
          <td><div className="document-actions"><button type="button" className="document-icon download" title="Download document" onClick={() => onDownload?.(doc.documentId)}><i className="bi bi-download" /></button>{canDelete(doc) && <button type="button" className="document-icon delete" title="Delete document" onClick={() => onDelete?.(doc.documentId)}><i className="bi bi-trash" /></button>}</div></td>
        </tr>) : <tr><td colSpan={5} className="empty-cell">No documents uploaded.</td></tr>}</tbody>
      </table>
    </div>
    <div className="document-pager"><button type="button" disabled><i className="bi bi-chevron-left" /></button><b>1</b><button type="button" disabled><i className="bi bi-chevron-right" /></button></div>
  </div>;
}
