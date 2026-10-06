import { useEffect, useState } from 'react';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import Modal from './Modal';
import { ErrorBox, Loading } from './Status';

/**
 * The mockup's "Process Automatic Adjustments" confirmation. claimKeys null = every eligible claim
 * in the lab; otherwise only those (ineligible ones are skipped by the API). Shows the API's preview
 * (count and $) before anything changes.
 */
export default function AutoAdjustModal({ labId, claimKeys, onClose, onDone }) {
  const [preview, setPreview] = useState(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  // Keyed by the list's content, so a parent re-render with a new (equal) array does not re-query.
  const keysKey = claimKeys ? claimKeys.join(',') : '*';
  useEffect(() => {
    arWorkbenchService.previewAutoAdjust(labId, claimKeys).then(setPreview).catch((e) => setError(e.message));
  }, [labId, keysKey]); // eslint-disable-line react-hooks/exhaustive-deps

  async function run() {
    setBusy(true);
    setError('');
    try {
      onDone(await arWorkbenchService.processAutoAdjust(labId, claimKeys));
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  const scope = claimKeys ? (claimKeys.length === 1 ? 'this claim' : `the ${fmt.count(claimKeys.length)} selected claims`) : 'every claim in this lab';
  const none = preview && preview.claimCount === 0;

  return (
    <Modal title="Process Automatic Adjustments" busy={busy} busyLabel="Adjusting…" onClose={onClose}
      onSubmit={none || !preview ? onClose : run} submitLabel={none || !preview ? null : 'Process Automatic Adjustments'}
      submitClass="arwb-btn-danger">
      <ErrorBox message={error} />
      {!preview && !error && <Loading text="Checking eligible claims…" />}
      {none && <p>None of {scope} is eligible: an automatic adjustment needs an open insurance balance and a primary denial on the Auto-Adjust list.</p>}
      {preview && !none && (
        <>
          <p>
            Automatically write off <b>{fmt.count(preview.claimCount)}</b> non-collectible denial{preview.claimCount === 1 ? '' : 's'} totaling{' '}
            <b>{fmt.money(preview.totalAmount)}</b> from {scope}?
          </p>
          <p className="arwb-hint">
            These match the denial-code master list and need no agent follow-up. The insurance balance is cleared in the workbench only,
            a System / Automation entry is added to each claim's activity, and the claims move to the <b>Auto Adjustments</b> queue
            until the adjustment is posted in the PMS and marked as posted.
          </p>
        </>
      )}
    </Modal>
  );
}
