// Navigation is data, not code. The sidebar AND the route guard both read this list, so a role's
// visible menu and its enforced access can never drift apart. Roles are the workbench role code the
// API derives from the user's LRNMaster role permissions (dbo.RoleFeatureAccess 'ARWorkbench.*').
//
// phase: the build phase from docs/Denial_WorkFlow/AR_Workbench_Open_Items_And_Phases.md.
// built: false renders the "planned" page for that route instead of a screen.
// Order, labels, icons (components/Icon) and subtitles follow the mockup's App.NAV / VIEW_META
// (docs/Denial_WorkFlow/LRN_Denial_AR_Workbench_Demo_Account.html); the subtitle shows in the topbar.
export const ALL_ROLES = ['admin', 'manager', 'lead', 'agent', 'qa', 'viewer'];

export const NAV = [
  { id: 'dashboard',       label: 'Dashboard',                          icon: 'dashboard', path: '/',                roles: ALL_ROLES,                             built: true,  phase: 1, subtitle: 'Denial & AR portfolio at a glance' },
  { id: 'data-processing', label: 'Data Processing',                    icon: 'layers',    path: '/data-processing', roles: ['admin', 'manager'],                  built: true,  phase: 1, subtitle: 'Weekly ETL status & Denial Analysis Report insights' },
  { id: 'workqueue',       label: 'Denial & AR Work Queue',             icon: 'inbox',     path: '/work-queue',      roles: ['admin', 'manager', 'lead', 'agent'], built: true,  phase: 2, subtitle: 'Filter, prioritize and route eligible claims', countKey: 'unassignedOpen' },
  { id: 'assignment',      label: 'Assignment Management',              icon: 'target',    path: '/assignment',      roles: ['admin', 'manager', 'lead'],          built: false, phase: 2, subtitle: 'Build batches and assign claims to AR agents' },
  { id: 'mywork',          label: 'My Work',                            icon: 'clipboard', path: '/my-work',         roles: ['agent', 'lead'],                     built: false, phase: 2, subtitle: 'Your assigned claims and today’s priorities' },
  { id: 'followup',        label: 'Follow-Up Management',               icon: 'phone',     path: '/follow-up',       roles: ['admin', 'manager', 'lead', 'agent'], built: false, phase: 3, subtitle: 'Claims waiting on your next touch', countKey: 'refollowupDue' },
  { id: 'qa',              label: 'QA Verification Queue',              icon: 'check',     path: '/qa',              roles: ['admin', 'manager', 'lead', 'qa'],    built: false, phase: 4, subtitle: 'Every logged follow-up note lands here automatically for review', countKey: 'awaitingQa' },
  { id: 'cip',             label: 'CIP Escalations',                    icon: 'warn',      path: '/cip',             roles: ['admin', 'manager', 'lead'],          built: false, phase: 5, subtitle: 'Client Involvement Process notes, tracked separately & ready to export for clients' },
  { id: 'agent-requests',  label: 'Escalation & Reassignment Requests', icon: 'flag',      path: '/agent-requests',  roles: ['admin', 'manager', 'lead'],          built: false, phase: 4, subtitle: 'Supervisor escalations and reassignment requests raised by AR agents' },
  { id: 'client-cip',      label: 'Escalation Requests',                icon: 'warn',      path: '/client-cip',      roles: ['viewer'],                            built: false, phase: 5, subtitle: 'Information your AR team needs from you — respond and attach documentation' },
  { id: 'analytics',       label: 'Recovery & Financial Analytics',     icon: 'trend',     path: '/analytics',       roles: ALL_ROLES,                             built: false, phase: 6, subtitle: 'Insurance AR recovery performance' },
  { id: 'reports',         label: 'Reports',                            icon: 'filetext',  path: '/reports',         roles: ALL_ROLES,                             built: false, phase: 6, subtitle: 'Exportable views for stakeholders' },
  { id: 'users',           label: 'User Management',                    icon: 'users',     path: '/users',           roles: ['admin'],                             built: false, phase: 4, subtitle: 'Roles, access and client assignments' },
  { id: 'audit',           label: 'Audit Logs',                         icon: 'shield',    path: '/audit',           roles: ['admin', 'manager'],                  built: false, phase: 4, subtitle: 'Immutable trail of workflow-changing actions' },
  { id: 'settings',        label: 'System Settings',                    icon: 'settings',  path: '/settings',        roles: ['admin'],                             built: true,  phase: 3, subtitle: 'Denial codes, workflow rules & TFL thresholds' }
];

// user is /me. A site admin (Super Admin for every lab, Lab Admin for their assigned labs) opens
// every page; everyone else gets their role's list.
export function allows(user, item) {
  return Boolean(user?.siteAdmin) || item.roles.includes(user?.roleCode);
}

export function navForUser(user) {
  return NAV.filter((item) => allows(user, item));
}

export function canOpen(user, id) {
  return NAV.some((item) => item.id === id && allows(user, item));
}
