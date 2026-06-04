import React from 'react';
import { statusClass } from '../utils/formatters';

export default function StatusBadge({ value, className = '' }) {
  const label = value || 'New';
  return <span className={`badge ${statusClass(label)} ${className}`.trim()}>{label}</span>;
}
