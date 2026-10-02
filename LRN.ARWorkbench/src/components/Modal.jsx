import { useEffect, useRef } from 'react';
import Icon from './Icon';

/**
 * A dialog as a form: Enter submits, Escape (and the X / Cancel) closes unless busy. The first
 * enabled field is focused on open. submitLabel null hides the submit button (an information dialog).
 */
export default function Modal({
  title, subtitle, onClose, onSubmit, submitLabel = 'Save', submitClass = 'arwb-btn-primary',
  busy = false, busyLabel = 'Saving…', wide = false, children
}) {
  const formRef = useRef(null);

  useEffect(() => {
    const onKey = (e) => { if (e.key === 'Escape' && !busy) onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [busy, onClose]);

  useEffect(() => {
    const first = formRef.current?.querySelector('input:not([readonly]):not([disabled]), select:not([disabled]), textarea:not([readonly])');
    (first || formRef.current?.querySelector('button[type=submit]'))?.focus();
  }, []);

  return (
    <div className="arwb-modal-backdrop">
      <form ref={formRef} className={`arwb-modal${wide ? ' wide' : ''}`} role="dialog" aria-modal="true" aria-label={title}
        onSubmit={(e) => { e.preventDefault(); if (!busy && onSubmit) onSubmit(); }}>
        <div className="arwb-modal-head">
          <div className="grow">
            <h3>{title}</h3>
            {subtitle && <small>{subtitle}</small>}
          </div>
          <button type="button" className="arwb-icon-btn" disabled={busy} onClick={onClose} aria-label="Close"><Icon name="close" size={16} /></button>
        </div>
        <div className="arwb-modal-body">{children}</div>
        <div className="arwb-modal-foot">
          <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" disabled={busy} onClick={onClose}>{submitLabel ? 'Cancel' : 'Close'}</button>
          {submitLabel && (
            <button type="submit" className={`arwb-btn arwb-btn-sm ${submitClass}`} disabled={busy}>
              {busy ? <><span className="arwb-spinner" /> {busyLabel}</> : submitLabel}
            </button>
          )}
        </div>
      </form>
    </div>
  );
}
