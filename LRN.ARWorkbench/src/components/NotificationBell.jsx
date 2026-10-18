import { useCallback, useEffect, useRef, useState } from 'react';
import { useLocation, useNavigate } from 'react-router';
import { canOpen } from '../config/navigation';
import { arWorkbenchService } from '../services/arWorkbenchService';
import { fmt } from '../utils/format';
import Icon from './Icon';

const POLL_MS = 60_000;

const TYPE_LABEL = {
  StatusChangeVerification: 'Status change',
  StatusVerificationResolved: 'Verified',
  NewDenial: 'New denial',
  AutoUnassigned: 'Unassigned',
  AdjustmentNotPosted: 'Adjustment not posted',
  WriteOffApproved: 'Write-off approved',
  CipClientResponded: 'CIP response'
};

/**
 * Top bar bell: the workbench notifications (dbo.ARWB_Notification) addressed to the signed-in user
 * or their role - e.g. an RCM Manager hears when the claim sync moves an assigned claim to Status
 * Change Verification. Refreshed every minute and on every page change.
 */
export default function NotificationBell({ labId, user }) {
  const navigate = useNavigate();
  const location = useLocation();
  const [data, setData] = useState(null);
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  const load = useCallback((signal) => arWorkbenchService.notifications(labId, signal)
    .then(setData)
    .catch(() => { /* the bell is optional; pages report their own errors */ }), [labId]);

  useEffect(() => {
    if (!labId || !user) return undefined;
    const controller = new AbortController();
    load(controller.signal);
    const timer = setInterval(() => load(controller.signal), POLL_MS);
    return () => { controller.abort(); clearInterval(timer); };
  }, [labId, user, location.pathname, load]);

  useEffect(() => {
    if (!open) return undefined;
    const onDown = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const onKey = (e) => { if (e.key === 'Escape') setOpen(false); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey); };
  }, [open]);

  async function markRead(body) {
    try { await arWorkbenchService.markNotificationsRead(labId, body); } catch { /* shown again next poll */ }
    load();
  }

  function openItem(n) {
    setOpen(false);
    if (!n.isRead) markRead({ notificationIds: [n.notificationId] });
    // A manager goes to the queue where the decision is made; everyone else to the claim.
    if (n.notificationType === 'StatusChangeVerification' && canOpen(user, 'status-verification')) navigate('/status-verification');
    else if (n.claimKey) navigate(`/claims/${n.claimKey}`);
  }

  const unread = data?.unreadCount || 0;
  const items = data?.items || [];

  return (
    <div className="arwb-user-menu" ref={ref}>
      <button type="button" className="arwb-icon-btn arwb-bell-btn" onClick={() => setOpen((v) => !v)}
        aria-haspopup="true" aria-expanded={open}
        aria-label={unread ? `Notifications, ${unread} unread` : 'Notifications'} title="Notifications">
        <Icon name="bell" />
        {unread > 0 && <span className="arwb-bell-count" aria-hidden="true">{unread > 99 ? '99+' : unread}</span>}
      </button>
      {open && (
        <div className="arwb-popover right arwb-bell-dropdown" role="dialog" aria-label="Notifications">
          <div className="arwb-bell-head">
            <b>Notifications</b>
            {unread > 0 && (
              <button type="button" className="arwb-btn arwb-btn-sm arwb-btn-ghost" onClick={() => markRead({ all: true })}>Mark all read</button>
            )}
          </div>
          {items.length === 0 ? (
            <div className="arwb-hint" style={{ padding: '10px 8px' }}>{data ? 'No notifications.' : 'Loading…'}</div>
          ) : (
            <ul className="arwb-bell-list">
              {items.map((n) => (
                <li key={n.notificationId}>
                  <button type="button" className={`arwb-bell-item${n.isRead ? '' : ' unread'}`} onClick={() => openItem(n)}>
                    <span className="arwb-bell-meta">
                      <b>{TYPE_LABEL[n.notificationType] || n.notificationType}</b>
                      {n.isRoleBroadcast && <span> · all {user?.roleCode === 'admin' ? 'managers' : 'your role'}</span>}
                      <span className="ms-auto">{fmt.dateTime(n.createdOn)}</span>
                    </span>
                    <span className="arwb-bell-msg">{n.message}</span>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
