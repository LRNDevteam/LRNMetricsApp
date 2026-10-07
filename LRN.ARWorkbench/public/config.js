/*
  AR Workbench - runtime settings for THIS deployment (copied to the root of dist/).

  Edit this file in the deployed folder to point the workbench at its own environment; no rebuild
  is needed. Blank values fall back to the build's .env settings (production by default).

  Test example (www.lrnanalytics.com/ARWBTest):
    lrnMetricsBaseUrl: 'https://www.lrnanalytics.com/TestLrnAnalytics',
    apiBaseUrl:        'https://www.lrnanalytics.com/<test ReportsApi path>/api/ar-workbench',

  lrnMetricsBaseUrl  LRN Metrics (LabMetricsDashboard) that owns login, the AuthToken and logout.
  apiBaseUrl         LRN.ReportsApi AR Workbench endpoint (.../api/ar-workbench) of the same environment.
  logoutUrl          Optional: where Log out goes. Blank = <lrnMetricsBaseUrl>/DenialWorkflow/Logout,
                     which signs out of LRN Metrics and returns to that site's login page.
  loginUrl           Optional: blank = <lrnMetricsBaseUrl>/Account/Login.

  The publish script keeps an existing config.js in the target folder, so redeploying does not
  reset an environment's settings.
*/
window.LRN_AR_WORKBENCH_CONFIG = {
    lrnMetricsBaseUrl: 'https://www.lrnanalytics.com/TestLrnAnalytics',
    apiBaseUrl: 'https://www.lrnanalytics.com/TestLrnApi/api/ar-workbench',
    logoutUrl: '',
    loginUrl: ''
};
