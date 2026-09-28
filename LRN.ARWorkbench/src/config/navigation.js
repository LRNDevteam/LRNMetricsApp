// Navigation is data, not code. The sidebar AND the route guard both read this list, so a role's
// visible menu and its enforced access can never drift apart. Roles are the workbench role code the
// API derives from the user's LRNMaster role permissions (dbo.RoleFeatureAccess 'ARWorkbench.*').
//
// phase: the build phase from docs/Denial_WorkFlow/AR_Workbench_Open_Items_And_Phases.md.
// built: false renders the "planned" page for that route instead of a screen.
export const ALL_ROLES = ['admin', 'manager', 'lead', 'agent', 'qa', 'viewer'];

export const NAV = [
  { id: 'dashboard',       label: 'Dashboard',                 icon: 'speedometer2',        path: '/',                roles: ALL_ROLES,                              built: true,  phase: 1 },
  { id: 'workqueue',       label: 'Work Queue',                icon: 'list-task',           path: '/work-queue',      roles: ['admin', 'manager', 'lead', 'agent'],  built: true,  phase: 2 },
  { id: 'assignment',      label: 'Assignment Management',     icon: 'people',              path: '/assignment',      roles: ['admin', 'manager', 'lead'],           built: false, phase: 2, countKey: 'unassignedOpen' },
  { id: 'mywork',          label: 'My Work',                   icon: 'person-workspace',    path: '/my-work',         roles: ['agent', 'lead'],                      built: false, phase: 2 },
  { id: 'followup',        label: 'Follow-Up Management',      icon: 'calendar-check',      path: '/follow-up',       roles: ['admin', 'manager', 'lead', 'agent'],  built: false, phase: 3, countKey: 'refollowupDue' },
  { id: 'qa',              label: 'QA Verification',           icon: 'patch-check',         path: '/qa',              roles: ['admin', 'manager', 'lead', 'qa'],     built: false, phase: 4, countKey: 'awaitingQa' },
  { id: 'agent-requests',  label: 'Escalation & Reassignment', icon: 'arrow-left-right',    path: '/agent-requests',  roles: ['admin', 'manager', 'lead'],           built: false, phase: 4 },
  { id: 'cip',             label: 'CIP & Escalations',         icon: 'megaphone',           path: '/cip',             roles: ['admin', 'manager', 'lead'],           built: false, phase: 5 },
  { id: 'client-cip',      label: 'Escalation Requests',       icon: 'envelope-open',       path: '/client-cip',      roles: ['viewer'],                             built: false, phase: 5 },
  { id: 'analytics',       label: 'Analytics',                 icon: 'bar-chart',           path: '/analytics',       roles: ALL_ROLES,                              built: false, phase: 6 },
  { id: 'reports',         label: 'Reports',                   icon: 'file-earmark-text',   path: '/reports',         roles: ALL_ROLES,                              built: false, phase: 6 },
  { id: 'data-processing', label: 'Data Processing',           icon: 'arrow-repeat',        path: '/data-processing', roles: ['admin', 'manager'],                   built: true,  phase: 1 },
  { id: 'audit',           label: 'Audit Logs',                icon: 'journal-text',        path: '/audit',           roles: ['admin', 'manager'],                   built: false, phase: 4 },
  { id: 'users',           label: 'User Management',           icon: 'person-gear',         path: '/users',           roles: ['admin'],                              built: false, phase: 4 },
  { id: 'settings',        label: 'Master File Maintenance',   icon: 'sliders',             path: '/settings',        roles: ['admin'],                              built: true,  phase: 3 }
];

export function navForRole(role) {
  return NAV.filter((item) => item.roles.includes(role));
}

export function canOpen(role, id) {
  return NAV.some((item) => item.id === id && item.roles.includes(role));
}
