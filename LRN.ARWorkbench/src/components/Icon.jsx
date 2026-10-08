// The mockup's stroke icon set (App.ICONS in docs/Denial_WorkFlow/LRN_Denial_AR_Workbench_Demo_Account.html),
// so the sidebar and cards use the same glyphs as the approved design.
const PATHS = {
  dashboard: <><rect x="2.5" y="2.5" width="6.2" height="6.2" rx="1.2" /><rect x="11.3" y="2.5" width="6.2" height="6.2" rx="1.2" /><rect x="2.5" y="11.3" width="6.2" height="6.2" rx="1.2" /><rect x="11.3" y="11.3" width="6.2" height="6.2" rx="1.2" /></>,
  layers: <><polyline points="10,3 17.5,7 10,11 2.5,7" /><polyline points="2.5,10.5 10,14.5 17.5,10.5" /><polyline points="2.5,14 10,18 17.5,14" /></>,
  inbox: <><polyline points="2.5,11 6.5,11 8,13.3 12,13.3 13.5,11 17.5,11" /><path d="M4 5.5 L2.5 11 V15.5 A1 1 0 0 0 3.5 16.5 H16.5 A1 1 0 0 0 17.5 15.5 V11 L16 5.5 A1 1 0 0 0 15 4.5 H5 A1 1 0 0 0 4 5.5Z" /></>,
  target: <><circle cx="10" cy="10" r="7" /><circle cx="10" cy="10" r="3.6" /><circle cx="10" cy="10" r="0.6" fill="currentColor" /></>,
  clipboard: <><rect x="4" y="4" width="12" height="14" rx="1.4" /><rect x="7.3" y="2.3" width="5.4" height="3" rx="1" /><line x1="6.7" y1="9.5" x2="13.3" y2="9.5" /><line x1="6.7" y1="12.7" x2="13.3" y2="12.7" /></>,
  phone: <path d="M4.2 3.5h2.6l1.1 3.3-1.7 1.5a10.4 10.4 0 0 0 4.5 4.5l1.5-1.7 3.3 1.1v2.6c0 .8-.7 1.4-1.5 1.3-6-.6-10.6-5.2-11.2-11.2-.1-.8.5-1.5 1.3-1.5Z" />,
  check: <><circle cx="10" cy="10" r="7.3" /><polyline points="6.7,10.2 8.8,12.3 13.3,7.6" /></>,
  trend: <><polyline points="2.7,14.5 7.3,9.5 10.7,12.3 17.3,4.8" /><polyline points="13,4.8 17.3,4.8 17.3,9.1" /></>,
  filetext: <><rect x="4.3" y="2.5" width="11.4" height="15" rx="1.2" /><line x1="7" y1="7" x2="13" y2="7" /><line x1="7" y1="10" x2="13" y2="10" /><line x1="7" y1="13" x2="11" y2="13" /></>,
  users: <><circle cx="7.6" cy="7" r="2.6" /><path d="M2.7 16.5c0-2.7 2.2-4.3 4.9-4.3s4.9 1.6 4.9 4.3" /><circle cx="14.3" cy="6.2" r="2" /><path d="M13.2 12.6c1.9.3 3.5 1.6 3.5 3.9" /></>,
  shield: <><path d="M10 2.3 16.5 4.8V9.6c0 4.2-2.8 6.9-6.5 8.1-3.7-1.2-6.5-3.9-6.5-8.1V4.8Z" /><polyline points="7,9.8 9.1,11.9 13.3,7.3" /></>,
  settings: <><circle cx="10" cy="10" r="2.9" /><line x1="10" y1="2.6" x2="10" y2="5" /><line x1="10" y1="15" x2="10" y2="17.4" /><line x1="17.4" y1="10" x2="15" y2="10" /><line x1="5" y1="10" x2="2.6" y2="10" /><line x1="15.2" y1="4.8" x2="13.5" y2="6.5" /><line x1="6.5" y1="13.5" x2="4.8" y2="15.2" /><line x1="15.2" y1="15.2" x2="13.5" y2="13.5" /><line x1="6.5" y1="6.5" x2="4.8" y2="4.8" /></>,
  close: <><line x1="5" y1="5" x2="15" y2="15" /><line x1="15" y1="5" x2="5" y2="15" /></>,
  menu: <><line x1="3" y1="5.5" x2="17" y2="5.5" /><line x1="3" y1="10" x2="17" y2="10" /><line x1="3" y1="14.5" x2="17" y2="14.5" /></>,
  key: <><circle cx="6.8" cy="13.2" r="3.3" /><line x1="9.2" y1="10.8" x2="16.5" y2="3.5" /><line x1="13.8" y1="6.2" x2="15.8" y2="8.2" /><line x1="12" y1="8" x2="13.6" y2="9.6" /></>,
  logout: <><path d="M8 4H4.5a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1H8" /><polyline points="12.5,6.5 16.5,10 12.5,13.5" /><line x1="16" y1="10" x2="7.3" y2="10" /></>,
  warn: <><path d="M10 3 17.5 16.5h-15Z" /><line x1="10" y1="8" x2="10" y2="11.6" /><line x1="10" y1="14" x2="10" y2="14" /></>,
  flag: <><line x1="5" y1="17.5" x2="5" y2="3" /><path d="M5 4c1.9-1.2 3.9-1.2 5.8 0 1.9 1.2 3.9 1.2 5.8 0v8c-1.9 1.2-3.9 1.2-5.8 0-1.9-1.2-3.9-1.2-5.8 0Z" /></>,
  calendar: <><rect x="3" y="4" width="14" height="13" rx="1.3" /><line x1="3" y1="8" x2="17" y2="8" /><line x1="7" y1="2.3" x2="7" y2="5.3" /><line x1="13" y1="2.3" x2="13" y2="5.3" /></>,
  refresh: <><path d="M16.5 10a6.5 6.5 0 1 1-1.9-4.6" /><polyline points="16.5,3.5 16.5,7 13,7" /></>,
  chevronDown: <polyline points="5,7.5 10,12.5 15,7.5" />,
  search: <><circle cx="8.7" cy="8.7" r="5.4" /><line x1="12.8" y1="12.8" x2="17" y2="17" /></>,
  filter: <polygon points="3,4 17,4 12,10.5 12,16 8,14 8,10.5" />,
  doc: <><path d="M6 2.5h6l4 4V17a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V3.5a1 1 0 0 1 1-1Z" /><polyline points="12,2.5 12,6.5 16,6.5" /></>,
  plus: <><line x1="10" y1="3.5" x2="10" y2="16.5" /><line x1="3.5" y1="10" x2="16.5" y2="10" /></>,
  edit: <><path d="M13.6 3.4a1.8 1.8 0 0 1 2.6 2.6L7 15.2l-3.5.9.9-3.5Z" /><line x1="12" y1="5" x2="14.6" y2="7.6" /></>,
  trash: <><line x1="3.5" y1="5.5" x2="16.5" y2="5.5" /><path d="M8 5.5V3.8h4v1.7" /><path d="M5 5.5l.8 11a1 1 0 0 0 1 .9h6.4a1 1 0 0 0 1-.9l.8-11" /></>,
  upload: <><line x1="10" y1="13" x2="10" y2="3.5" /><polyline points="6,7.5 10,3.5 14,7.5" /><path d="M3.5 13v2.5a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1V13" /></>,
  download: <><line x1="10" y1="3.5" x2="10" y2="13" /><polyline points="6,9 10,13 14,9" /><path d="M3.5 13v2.5a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1V13" /></>,
  building: <><rect x="4" y="3" width="12" height="14.5" rx="1" /><line x1="7.5" y1="6.5" x2="8.5" y2="6.5" /><line x1="11.5" y1="6.5" x2="12.5" y2="6.5" /><line x1="7.5" y1="9.5" x2="8.5" y2="9.5" /><line x1="11.5" y1="9.5" x2="12.5" y2="9.5" /><rect x="8.5" y="13" width="3" height="4.5" /></>,
  star: <polygon points="10,2.8 12.2,7.4 17.2,8 13.5,11.4 14.5,16.4 10,13.9 5.5,16.4 6.5,11.4 2.8,8 7.8,7.4" />,
  starFill: <polygon points="10,2.8 12.2,7.4 17.2,8 13.5,11.4 14.5,16.4 10,13.9 5.5,16.4 6.5,11.4 2.8,8 7.8,7.4" fill="currentColor" />,
  save: <><path d="M4 3h9.5L17 6.5V16a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1Z" /><rect x="6" y="11" width="8" height="6" /><line x1="6.5" y1="3" x2="6.5" y2="7" /><line x1="6.5" y1="7" x2="12" y2="7" /></>,
  arrowLeft:<><line x1="16" y1="10" x2="4" y2="10" /><polyline points="9,5 4,10 9,15" /></>
};

export default function Icon({ name, size = 17 }) {
  const inner = PATHS[name];
  if (!inner) return null;
  return (
    <svg viewBox="0 0 20 20" width={size} height={size} fill="none" stroke="currentColor" strokeWidth="1.6"
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {inner}
    </svg>
  );
}
