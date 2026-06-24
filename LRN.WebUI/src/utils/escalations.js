const normalizeText = value => String(value ?? '').trim().replace(/\s+/g, ' ').toLowerCase();

function dateBucket(value) {
  if (!value) return '';
  const time = new Date(value).getTime();
  if (!Number.isFinite(time)) return '';
  return String(Math.floor(time / 60000));
}

export function dedupeEscalations(rows = []) {
  const seen = new Set();
  return (rows || []).filter(row => {
    const key = [
      normalizeText(row.claimId),
      normalizeText(row.taskId),
      normalizeText(row.cptCode),
      normalizeText(row.escalationLevel),
      normalizeText(row.escalationReason),
      normalizeText(row.comments),
      normalizeText(row.status),
      normalizeText(row.escalatedTo),
      normalizeText(row.createdBy),
      dateBucket(row.nextFollowUpDate),
      dateBucket(row.createdOn)
    ].join('|');

    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
