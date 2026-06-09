import React, { useState } from 'react';
import { denialWorkflowService } from '../services/denialWorkflowService';

const MAX_MESSAGE_LENGTH = 4000;
const issueTypes = ['Workflow issue', 'Data issue', 'Access issue', 'Export issue', 'Performance issue', 'Other'];
const priorities = ['Normal', 'High', 'Urgent'];

export default function ContactSupportPage({ user, currentPage = '', setMessage }) {
  const [form, setForm] = useState({
    issueType: 'Workflow issue',
    priority: 'Normal',
    subject: '',
    contactEmail: user?.email || user?.Email || '',
    message: ''
  });
  const [sending, setSending] = useState(false);

  const canSend = form.subject.trim() && form.message.trim() && !sending;

  function setField(field, value) {
    setForm(prev => ({ ...prev, [field]: field === 'message' ? value.slice(0, MAX_MESSAGE_LENGTH) : value }));
  }

  async function submitIssue(e) {
    e.preventDefault();
    if (!canSend) return;

    setSending(true);
    try {
      const result = await denialWorkflowService.submitSupportRequest({
        ...form,
        page: currentPage || window.location.hash || window.location.pathname
      });
      setMessage?.({
        type: result?.teamsSent ? 'success' : 'warning',
        text: result?.message || 'Support request submitted.'
      });
      setForm(prev => ({ ...prev, subject: '', message: '', priority: 'Normal' }));
    } catch (err) {
      setMessage?.({ type: 'danger', text: err.message || 'Unable to send support request.' });
    } finally {
      setSending(false);
    }
  }

  return <div className="support-page">
    <section className="support-hero compact">
      <div>
        <span className="support-kicker">Admin Support</span>
        <h2>Contact Support</h2>
        <p>Send workflow issues, access concerns, data questions, or export problems directly to the configured Teams support channel.</p>
      </div>
    </section>

    <form className="support-form-card" onSubmit={submitIssue}>
      <div className="support-form-grid">
        <label>Issue Type
          <select value={form.issueType} onChange={e => setField('issueType', e.target.value)}>
            {issueTypes.map(x => <option key={x} value={x}>{x}</option>)}
          </select>
        </label>
        <label>Priority
          <select value={form.priority} onChange={e => setField('priority', e.target.value)}>
            {priorities.map(x => <option key={x} value={x}>{x}</option>)}
          </select>
        </label>
        <label>Contact Email
          <input type="email" value={form.contactEmail} onChange={e => setField('contactEmail', e.target.value)} placeholder="your.email@company.com" />
        </label>
      </div>
      <label>Subject
        <input value={form.subject} maxLength={160} onChange={e => setField('subject', e.target.value)} placeholder="Short summary of the issue" />
      </label>
      <label>Issue Details
        <textarea value={form.message} onChange={e => setField('message', e.target.value)} placeholder="Tell support what happened, which claim/page you were on, and what action you were trying to complete." />
      </label>
      <div className="support-form-footer">
        <span>{form.message.length}/{MAX_MESSAGE_LENGTH}</span>
        <button type="submit" className="topbar-btn teal" disabled={!canSend}>
          <i className="bi bi-send" />{sending ? 'Sending...' : 'Send Message'}
        </button>
      </div>
    </form>
  </div>;
}
