import React, { useEffect, useRef } from 'react';

// Small dependency-free rich text box for Denial Summary observations: bold, italic, underline,
// bullet and numbered lists. The API re-sanitizes whatever this produces to formatting tags with
// no attributes, so pasting is forced to plain text to keep foreign markup out of the editor.
const TOOLS = [
  { command: 'bold', icon: 'bi-type-bold', label: 'Bold' },
  { command: 'italic', icon: 'bi-type-italic', label: 'Italic' },
  { command: 'underline', icon: 'bi-type-underline', label: 'Underline' },
  { command: 'insertUnorderedList', icon: 'bi-list-ul', label: 'Bulleted list' },
  { command: 'insertOrderedList', icon: 'bi-list-ol', label: 'Numbered list' },
  { command: 'removeFormat', icon: 'bi-eraser', label: 'Clear formatting' }
];

export default function RichTextEditor({ value, onChange, placeholder = '', disabled = false }) {
  const ref = useRef(null);

  // Only push external value into the DOM when it differs; rewriting innerHTML on every keystroke
  // would move the caret to the start.
  useEffect(() => {
    if (ref.current && ref.current.innerHTML !== (value || '')) ref.current.innerHTML = value || '';
  }, [value]);

  function run(command) {
    if (disabled) return;
    ref.current?.focus();
    document.execCommand(command, false, null);
    onChange?.(ref.current?.innerHTML || '');
  }

  function handlePaste(e) {
    e.preventDefault();
    const text = e.clipboardData?.getData('text/plain') || '';
    document.execCommand('insertText', false, text);
  }

  return (
    <div className={`rte ${disabled ? 'disabled' : ''}`}>
      <div className="rte-toolbar" role="toolbar" aria-label="Formatting">
        {TOOLS.map(t => (
          <button key={t.command} type="button" className="rte-tool" title={t.label} aria-label={t.label}
            disabled={disabled} onMouseDown={e => e.preventDefault()} onClick={() => run(t.command)}>
            <i className={`bi ${t.icon}`} />
          </button>
        ))}
      </div>
      <div
        ref={ref}
        className="rte-content"
        contentEditable={!disabled}
        suppressContentEditableWarning
        role="textbox"
        aria-multiline="true"
        data-placeholder={placeholder}
        onInput={e => onChange?.(e.currentTarget.innerHTML)}
        onPaste={handlePaste}
      />
    </div>
  );
}
