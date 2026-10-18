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
  { id: 'assignment',      label: 'Assignment Management',              icon: 'target',    path: '/assignment',      roles: ['admin', 'manager', 'lead'],          built: true,  phase: 2, subtitle: 'Build batches and assign claims to AR agents' },
  { id: 'mywork',          label: 'My Work',                            icon: 'clipboard', path: '/my-work',         roles: ['agent', 'lead'],                     built: true,  phase: 2, subtitle: 'Your assigned claims and today’s priorities' },
  { id: 'followup',        label: 'Follow-Up Management',               icon: 'phone',     path: '/follow-up',       roles: ['admin', 'manager', 'lead', 'agent'], built: true,  phase: 3, subtitle: 'Claims waiting on your next touch', countKey: 'refollowupDue' },
  { id: 'qa',              label: 'QA Verification Queue',              icon: 'check',     path: '/qa',              roles: ['admin', 'manager', 'lead', 'qa'],    built: true,  phase: 4, subtitle: 'Every logged follow-up note lands here automatically for review', countKey: 'awaitingQa' },
  { id: 'status-verification', label: 'Status Change Verification',     icon: 'swap',      path: '/status-verification', roles: ['admin', 'manager'],              built: true,  phase: 4, subtitle: 'Assigned claims whose claim status changed in the latest master file, held for RCM Manager verification', countKey: 'statusVerificationPending' },
  { id: 'cip',             label: 'CIP Escalations',                   icon: 'warn',      path: '/cip',             roles: ['admin', 'manager', 'lead'],          built: true, phase: 5, subtitle: 'Client Involvement Process notes, tracked separately & ready to export for clients' },
  { id: 'agent-requests',  label: 'Escalation & Reassignment Requests', icon: 'flag',      path: '/agent-requests',  roles: ['admin', 'manager', 'lead'],          built: true,  phase: 4, subtitle: 'Supervisor escalations and reassignment requests raised by AR agents', countKey: 'agentRequestsPending' },
  { id: 'client-cip',      label: 'Escalation Requests',                icon: 'warn',      path: '/client-cip',      roles: ['viewer'],                            built: true, phase: 5, subtitle: 'Information your AR team needs from you — respond and attach documentation' },
  { id: 'analytics',       label: 'Recovery & Financial Analytics',     icon: 'trend',     path: '/analytics',       roles: ALL_ROLES,                             built: true,  phase: 6, subtitle: 'Insurance AR recovery performance' },
  { id: 'reports',         label: 'Reports',                            icon: 'filetext',  path: '/reports',         roles: ALL_ROLES,                             built: true,  phase: 6, subtitle: 'Exportable views for stakeholders' },
  { id: 'documents',       label: 'Document Vault',                     icon: 'filetext',  path: '/documents',       roles: ALL_ROLES,                             built: true,  phase: 5, subtitle: 'Claim documents — appeals, EOBs, medical records, CIP responses — by claim / visit, patient and category' },
  { id: 'downloads',       label: 'My Downloads',                       icon: 'download',  path: '/downloads',       roles: ALL_ROLES,                             built: true,  phase: 6, subtitle: 'Every export you started — in progress, ready to download, and history' },
  { id: 'users',           label: 'User Management',                    icon: 'users',     path: '/users',           roles: ['admin'],                             built: true,  phase: 4, subtitle: 'Roles, access and client assignments' },
  { id: 'clients',         label: 'Client Management',                  icon: 'building',  path: '/clients',         roles: ['admin'],                             built: true,  phase: 3, subtitle: 'Laboratory clients: eligible claims, AR, recovery and activation' },
  { id: 'audit',           label: 'Audit Logs',                         icon: 'shield',    path: '/audit',           roles: ['admin', 'manager'],                  built: true,  phase: 4, subtitle: 'Immutable trail of workflow-changing actions' },
  // A menu group: no page of its own; each child is a route. screen + view pick the page component
  // and the part of it to show (App.jsx SCREENS). A child without its own roles inherits the group's.
  // Handoff §10: the RCM Manager maintains the Non-Collectible and Auto-Adjust lists (Workbench Lists,
  // DEF-08); every other master stays with the administrator.
  { id: 'masters',         label: 'Master Values',                      icon: 'settings',  path: '/masters',         roles: ['admin', 'manager'],                  built: true,  phase: 3, subtitle: 'Denial codes, dropdown lists and workbench reference data',
    children: [
      { id: 'super-master',    label: 'Denial Code Master',         path: '/masters/super-master',    screen: 'denial-codes',  view: 'super',     roles: ['admin'], subtitle: 'The Denial Workflow’s Denial Mapper Super Master (all labs) — edit, import & export' },
      { id: 'code-descriptions', label: 'Denial Code Descriptions', path: '/masters/code-descriptions', screen: 'code-master',                   roles: ['admin'], subtitle: 'One description, action category and attributes per code (PR4 / CO4 / PI4 = 4) for every lab, plus the Non-Collectible codes' },
      { id: 'mapper-lists',   label: 'Denial Mapper Lists',        path: '/masters/mapper-lists',    screen: 'master-values', view: 'mapper',    roles: ['admin'], subtitle: 'Super Master dropdowns: classification, coverage, ICD, validity, action category, SLA, priority (all labs)' },
      { id: 'workbench-lists', label: 'Workbench Lists',            path: '/masters/workbench-lists', screen: 'master-values', view: 'workbench', roles: ['admin', 'manager'], subtitle: 'AR Workbench reference lists that drive queues and follow-up capture (this lab)' },
      { id: 'category-map',    label: 'Workbench Category Map',     path: '/masters/category-map',    screen: 'denial-codes',  view: 'master',    roles: ['admin'], subtitle: 'Denial code to workbench denial category, read by the claim sync — edit, import & apply to claims' },
      { id: 'unmapped-codes',  label: 'Unmapped Codes',             path: '/masters/unmapped',        screen: 'denial-codes',  view: 'unmapped',  roles: ['admin'], subtitle: 'Denial codes on claims with no active category mapping' },
      { id: 'fix-resolution',  label: 'Fix / Resolution by Status', path: '/masters/fix-resolution',  screen: 'master-values', view: 'fix',       roles: ['admin'], subtitle: 'Which Fix / Resolution options a follow-up note offers for each claim status' },
      { id: 'tfl-limits',      label: 'Timely Filing Limits',       path: '/masters/tfl',             screen: 'tfl-limits',                       roles: ['admin'], subtitle: 'Timely-filing limit per financial class, default limit and TFL risk window' },
      { id: 'sla-targets',     label: 'Operational SLA Targets',    path: '/masters/sla',             screen: 'sla-targets',                      roles: ['admin'], subtitle: 'Target days per workflow milestone, measured by the Operational SLA report (RPT-09)' }
    ] }
];

// Old links (bookmarks, earlier builds) -> where that screen lives now.
export const REDIRECTS = { '/settings': '/masters/mapper-lists', '/denial-codes': '/masters/super-master' };

// Every routable page: top-level items without children, plus each group's children carrying the
// group's roles, built flag and phase, and the group itself for the sidebar.
export const ROUTES = NAV.flatMap((item) => (item.children
  ? item.children.map((child) => ({ icon: item.icon, roles: item.roles, built: item.built, phase: item.phase, group: item.id, groupLabel: item.label, ...child }))
  : [item]));

// user is /me. A site admin (Super Admin for every lab, Lab Admin for their assigned labs) opens
// every page; everyone else gets their role's list.
export function allows(user, item) {
  return Boolean(user?.siteAdmin) || item.roles.includes(user?.roleCode);
}

export function navForUser(user) {
  return NAV.filter((item) => allows(user, item))
    .map((item) => (item.children
      ? { ...item, children: item.children.filter((child) => allows(user, { roles: item.roles, ...child })) }
      : item))
    .filter((item) => !item.children || item.children.length > 0);
}

export function canOpen(user, id) {
  return ROUTES.some((item) => item.id === id && allows(user, item));
}
