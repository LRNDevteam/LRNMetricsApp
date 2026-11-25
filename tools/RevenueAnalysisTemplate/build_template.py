"""
Builds LabMetricsDashboard/Templates/RevenueAnalysis/RevenueAnalysisTemplate.html from the
report team's client dashboard (docs/dashboard/Dekalb_Pediatric_Center_Revenue_Analysis_*.html).

The client file is a single self-contained page: CSS + Chart.js + markup + one script that
recomputes every page from three embedded data blobs. This script keeps all of that and:

  * replaces the three data blobs with placeholders the dashboard app fills per lab
    (RevenueAnalysisBuilder.cs writes them in exactly the same columnar format);
  * replaces client-specific values (practice name, generation date, DOS window, CPT
    dictionary, file names) with placeholders;
  * relabels the Medicat / pediatric vocabulary for lab claim data:
        Order Type -> Panel, Insurance Group -> Payer Type, Billing Provider -> Clinic,
        Rendering Provider -> Referring Provider, External Number -> Claim ID;
  * hides the pediatric-only panels (new patients, E/M levels, well-child visits);
  * adds #page deep links so the app can open each page in its own window.

Run it again whenever the report team ships a new version of the dashboard:

    python -I tools/RevenueAnalysisTemplate/build_template.py <client.html> [<output.html>]

Every replacement is asserted, so a changed source fails loudly instead of producing a
half-converted template.
"""
import base64
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..'))
DEFAULT_OUT = os.path.join(REPO, 'LabMetricsDashboard', 'Templates', 'RevenueAnalysis', 'RevenueAnalysisTemplate.html')
LOGO = os.path.join(REPO, 'LabMetricsDashboard', 'wwwroot', 'images', 'LRN-White-Logo-footer-1-1.png')


def fail(msg):
    sys.stderr.write('build_template: ' + msg + '\n')
    sys.exit(1)


def rep(text, old, new, count=1, where=''):
    """Replace exactly `count` occurrences (count=None: at least one, all of them)."""
    n = text.count(old)
    if count is None:
        if n == 0:
            fail(f'expected at least one {old[:80]!r} in {where}')
    elif n != count:
        fail(f'expected {count} x {old[:80]!r} in {where}, found {n}')
    return text.replace(old, new)


def rep_re(text, pattern, new, count=1, where='', flags=re.S):
    out, n = re.subn(pattern, new, text, flags=flags)
    if n != count:
        fail(f'expected {count} match(es) of /{pattern[:80]}/ in {where}, found {n}')
    return out


def main():
    if len(sys.argv) < 2:
        fail('usage: build_template.py <client.html> [<output.html>]')
    src, out = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT)
    html = open(src, encoding='utf-8').read()

    # ---------------------------------------------------------------- split
    # head (CSS) | Chart.js | markup | data blobs | app script
    s1 = html.index('<script>')
    e1 = html.index('</script>', s1) + len('</script>')
    blob_start = html.index('<script id="data-blob"')
    app_start = html.index('<script>', html.index('<script id="lineexport-blob"'))
    head, chartjs, markup, app = html[:s1], html[s1:e1], html[e1:blob_start], html[app_start:]

    blobs = ('<script id="data-blob" type="application/json">__LRN_DATA_BLOB__</script>\n'
             '<script id="line-blob" type="application/json">__LRN_LINE_BLOB__</script>\n'
             '<script id="lineexport-blob" type="text/plain">__LRN_LINEEXPORT_BLOB__</script>\n')

    # ---------------------------------------------------------------- head / CSS
    head = rep(head, '<title>Dekalb Pediatric Center Revenue Intelligence · LRN</title>',
               '<title>__LRN_LAB_NAME__ Revenue Analysis · LRN</title>', where='head')
    head = rep(head, 'Dekalb', 'LRN Lab', count=None, where='head')
    lab_css = """
/* ============ LRN Lab Metrics adaptation (tools/RevenueAnalysisTemplate/build_template.py) ============ */
.brand-logo-plate{background:transparent!important;box-shadow:none!important;border:0!important;padding:6px 0!important;}
/* Pediatric-only analyses: lab claims carry no new-patient, E/M office-visit or well-child codes. */
.panel:has(#kpi-np), .panel:has(#chart-np-mix), #insights-np,
.grid-2:has(#chart-cpt-em), .panel:has(#chart-prov-em), .panel:has(#prov-code-table){display:none!important;}
"""
    idx = head.rindex('</style>')
    head = head[:idx] + lab_css + head[idx:]

    # ---------------------------------------------------------------- markup
    if not os.path.exists(LOGO):
        fail('logo not found: ' + LOGO)
    logo_uri = 'data:image/png;base64,' + base64.b64encode(open(LOGO, 'rb').read()).decode('ascii')
    markup = rep_re(markup, r'<img src="data:image/svg\+xml;base64,[^"]+" alt="Superior Billing Solutions" class="brand-logo-img"/>',
                    f'<img src="{logo_uri}" alt="LRN" class="brand-logo-img"/>', where='markup')
    markup = rep(markup, 'Billing partner: Superior Billing Solutions', 'Data: __LRN_SOURCE_LABEL__', where='markup')
    markup = rep(markup, '<b>Medicat Reports</b>', '<b>__LRN_SOURCE_SHORT__</b>', where='markup')
    markup = rep(markup, 'Four numbers that always add up to 100% of what Dekalb Pediatric Center billed.',
                 'Four numbers that should add up to 100% of what __LRN_LAB_NAME__ billed.', where='markup')

    # Sentences that were about Medicat / the pediatric extract, rewritten for lab data.
    markup = rep(markup, 'Payments posted in Medicat each month', 'Payments posted each month', where='markup')
    markup = rep(markup, "Medicat's Insurance Group field.", "The claim's Payer Type field.", where='markup')
    markup = rep(markup, "Medicat's Billing Method on each claim — who the charge is billed to.",
                 'Derived from each claim — whether insurance, the patient, or both carry the charge.', where='markup')
    markup = rep(markup, "Medicat's Claim Status field — a second lens",
                 'Claim Status (derived from balances and the non-collectible denial master) — a second lens', where='markup')
    markup = rep(markup, 'The resting state Medicat assigns to each claim.',
                 "The resting state derived from each claim's LIS claim status and balances.", where='markup')
    markup = rep(markup, 'if Medicat carries a denial code on it', 'if the claim carries a denial code', where='markup')
    markup = rep(markup, ' "Procedure" and "Procedures" are combined.', '', where='markup')
    markup = rep(markup, "Dekalb's Medicat extract has no clinic or rendering-provider field, so these scorecards split performance by what was ordered and how it was billed instead. ",
                 'These scorecards split performance by what was ordered and how it was billed. ', where='markup')
    markup = rep(markup, 'Lines add up exactly to the claim-level totals used elsewhere.',
                 'Line totals come from the Line Level master and can differ slightly from the claim-level totals used elsewhere.', where='markup')
    markup = rep(markup, 'CPT descriptions are short reference labels.',
                 'CPT descriptions are the Clinical Laboratory Fee Schedule short descriptions (Master Values › Fees Schedule Import).', where='markup')
    markup = rep_re(markup, r'<div>View the page by <b>billing provider</b>.*?listed in the directory\.</div>',
                    '<div>View the page by <b>clinic</b> or <b>referring provider</b> with the toggle below. Everything is built from the CPT lines: '
                    'the clinic is the same on every line of a claim, while the referring provider is read from each line, so a claim\'s dollars '
                    'follow the provider recorded on each of its lines. Claim counts, collections, denials and open AR use the claims each clinic or '
                    'provider has lines on; modifier and zero-paid figures come from the lines themselves. The sales rep(s) behind each clinic are '
                    'listed next to its name in the directory.</div>', where='markup')
    markup = rep_re(markup, r'<b>DOS</b> and <b>Order Type \(primary\)</b> are taken from.*?which is often blank\.</div>',
                    '<b>Panel (primary)</b> and <b>Referring Provider (primary)</b> are the claim\'s own values from the Claim Level master.</div>',
                    where='markup')
    markup = rep(markup, 'in the same layout as the CPT (Line) Level sheet with AR Category and Claim Status added',
                 'from the Line Level master with AR Category and Claim Status added', where='markup')
    markup = rep(markup, '<b>Built from the CPT (Line) Level sheet.</b>', '<b>Built from the Line Level master.</b>', where='markup')
    markup = rep(markup, '<span>Provider Analysis</span>', '<span>Clinic &amp; Provider</span>', where='markup')
    markup = rep(markup, 'Medicat ', '', count=None, where='markup')
    markup = rep(markup, "Dekalb's claims", "__LRN_LAB_NAME__'s claims", where='markup')
    markup = rep(markup, 'Dekalb Pediatric Center', '__LRN_LAB_NAME__', where='markup')
    if 'Dekalb' in markup or 'Medicat' in markup:
        fail('markup still mentions Dekalb / Medicat')

    # ---------------------------------------------------------------- app script: values
    app = rep(app, "const VALID_FROM = '2025-01';", "const VALID_FROM = '__LRN_VALID_FROM__';", where='app')
    app = rep(app, 'const GEN_DAY = 20776;', 'const GEN_DAY = __LRN_GEN_DAY__;', where='app')
    app = rep(app, "const GENERATED = 'Nov 19, 2026';", "const GENERATED = '__LRN_GENERATED__';", where='app')
    app = rep_re(app, r"document\.getElementById\('foot-period'\)\.textContent = '[^']*';",
                 "document.getElementById('foot-period').textContent = '__LRN_PERIOD__';", where='app')
    app = rep_re(app, r'const CPT_INFO = \{.*?\};\n', 'const CPT_INFO = __LRN_CPT_INFO__;\n', where='app')
    app = rep_re(app, r"const CPT_CAT_ORDER = \[[^\]]*\];",
                 "const CPT_CAT_ORDER = ['Drug Testing (Toxicology)','Molecular Pathology','Multianalyte Assays (MAAA)','Proprietary Lab Analyses (PLA)',"
                 "'Infectious Disease (Molecular)','Microbiology','Chemistry','Organ / Disease Panels','Hematology & Coagulation','Immunology',"
                 "'Urinalysis','Anatomic & Surgical Pathology','Cytopathology','Transfusion Medicine','Other Pathology & Lab','Specimen Collection & Handling',"
                 "'Evaluation & Management','HCPCS Level II','Other Codes'];", where='app')
    app = rep_re(app, r"const MOD_MEANING = \{",
                 "const MOD_MEANING = {'90':'Reference (outside) laboratory','91':'Repeat clinical diagnostic lab test','92':'Alternative lab platform testing',"
                 "'XU':'Unusual non-overlapping service','XE':'Separate encounter','XS':'Separate structure/organ','XP':'Separate practitioner',"
                 "'GA':'Waiver of liability (ABN) on file','GZ':'Item expected to be denied, no ABN','GY':'Statutorily excluded service','KX':'Policy requirements met',"
                 "'33':'Preventive service','26':'Professional component','TC':'Technical component','QP':'Documentation on file (organ/disease panel)',", where='app')
    app = rep(app, "if (ym === PRE) return 'Pre-2025';", "if (ym === PRE) return 'Pre-' + VALID_FROM.slice(0,4);", where='app')
    app = rep(app, "if (ym === PRE) return 'before Jan 2025';", "if (ym === PRE) return 'before ' + monthLabelLong(VALID_FROM);", where='app')
    app = rep(app, "m===PRE?'Before Jan 2025':monthLabelLong(m)", "m===PRE?'Before '+monthLabelLong(VALID_FROM):monthLabelLong(m)", where='app')
    app = rep(app, 'line postings dated before Jan 2025', 'line postings dated before ${monthLabelLong(VALID_FROM)}', where='app')
    app = rep(app, 'erroneous dates before Jan 2025', 'erroneous dates before ${monthLabelLong(VALID_FROM)}', where='app')
    app = rep(app, 'before the January 2025 DOS period', 'before the ${monthLabelLong(VALID_FROM)} DOS period', where='app')
    app = rep(app,
              "  if (ms.includes('2025-01')) out.push({id:'y25', l:'2025', from:'2025-01', to:'2025-12'});\n"
              "  if (ms.some(m=>m.startsWith('2026'))) out.push({id:'y26', l:'2026 YTD', from:'2026-01', to:last});\n",
              "  const curY = last.slice(0,4), prevY = String(Number(curY)-1);\n"
              "  if (ms.some(m=>m.startsWith(prevY))) out.push({id:'yprev', l:prevY, from:prevY+'-01', to:prevY+'-12'});\n"
              "  if (ms.some(m=>m.startsWith(curY))) out.push({id:'ycur', l:curY+' YTD', from:curY+'-01', to:last});\n", where='app')
    app = rep(app, 'dekalb_pediatric_', '__LRN_FILE_TAG___', count=2, where='app')

    # Waterfall footnote: lab data does not always reconcile to the cent, so say so instead of
    # asserting that it does.
    app = rep_re(app, r"footEl\.innerHTML = `✓ <b>Total Payments \+ Total Adjustments \+ Insurance Balance \+ Patient Balance = \$\{fmtMoneyFull\(billed\)\}</b> — 100% of billed charges\.\s*Payments include both insurance and patient payments posted in Medicat\.`;",
                 "const sum4 = paid + adjustments + patient_balance + insurance_balance, gap = billed - sum4;\n"
                 "    footEl.innerHTML = Math.abs(gap) <= Math.max(1, Math.abs(billed)*0.0005)\n"
                 "      ? `✓ <b>Total Payments + Total Adjustments + Insurance Balance + Patient Balance = ${fmtMoneyFull(billed)}</b> — 100% of billed charges. Payments include both insurance and patient payments.`\n"
                 "      : `<b>Payments + Adjustments + Insurance Balance + Patient Balance = ${fmtMoneyFull(sum4)}</b> against ${fmtMoneyFull(billed)} billed — "
                 "${fmtMoneyFull(Math.abs(gap))} (${(Math.abs(gap)/(Math.abs(billed)||1)*100).toFixed(1)}%) ${gap>0?'is not yet accounted for by a payment, adjustment or balance':'more than was billed (credits or overpayments)'} in the source data.`;",
                 where='app')

    # Pediatric-specific narrative.
    app = rep(app, '— consistent with January well-child and deductible-reset visit patterns in pediatrics.',
              '— worth checking against seasonal ordering patterns and January deductible resets.', where='app')
    app = rep(app, "html:`Denials are low overall: <b>",
              "html:`${o.denial_rate<0.1?'Denials are low overall':'Denials are a material share of volume'}: <b>", where='app')
    app = rep_re(app, r"topCat\.category==='Bundling'\?'For a pediatric practice[^']*'",
                 "topCat.category==='Bundling'?'For a lab this usually means panel components billed alongside the panel, or repeat / distinct tests billed without modifier 59, 91 or XU — a coding-rule fix, not a follow-up problem.'",
                 where='app')
    app = rep(app, 'worth checking that payer\'s modifier rules against how Dekalb bills.',
              'worth checking that payer\'s modifier rules against how __LRN_LAB_NAME__ bills.', where='app')
    app = rep(app, "Most of Dekalb's payers", 'Most payers', where='app')
    app = rep(app, 'Medicat marks ${', 'The non-collectible denial master marks ${', where='app')

    app = rep(app, "provider:  {title:'Provider Analysis', desc:\"Charges, payments, collections, denials, open AR and coding patterns by rendering provider.\"}",
              "provider:  {title:'Clinic & Provider Analysis', desc:\"Charges, payments, collections, denials and open AR by clinic or referring provider.\"}", where='app')

    # Account snapshot counts g('prov') = clinics.
    app = rep(app, "{l:'Rendering Providers', v:fmtInt(o.unique_provs), s:'Providers with claims in this selection'}",
              "{l:'Clinics', v:fmtInt(o.unique_provs), s:'Clinics with claims in this selection'}", where='app')

    # Source Data: the claim-sheet duplicate columns and the new-patient flag do not exist for labs.
    for key in ('otype0', 'dos0', 'rprov0', 'np', 'rprovc'):
        app = rep_re(app, r"\n  \{k:'" + key + r"', h:'[^']*', v:i=>[^\n]*\},", '', where='app SD_COLS ' + key)
    app = rep(app, "{k:'provc', h:'Billing Provider Code'", "{k:'provc', h:'Sales Rep'", where='app')
    app = rep(app, "'Billing Provider Code','Billing Provider Name','Rendering Provider Code','Rendering Provider Name'",
              "'Sales Rep','Clinic','Referring Provider Code','Referring Provider'", where='app')

    # Deep links: every page has its own URL (#payer, #denial, ...) so the app can open each
    # page in its own window, and the window title says which page it is.
    app = rep(app, "  window.scrollTo({top:0,behavior:'smooth'});\n}",
              "  document.title = PAGE_META[page].title + ' · __LRN_LAB_NAME__ · LRN';\n"
              "  if (location.hash !== '#'+page) { try { history.replaceState(null, '', '#'+page); } catch(e){} }\n"
              "  window.scrollTo({top:0,behavior:'smooth'});\n}", where='app')
    app = rep(app, 'sdInit();\nrebuild();\n',
              "sdInit();\nrebuild();\n"
              "(function(){\n"
              "  const fromHash = () => { const p = (location.hash||'').slice(1); if (p && PAGE_META[p] && document.getElementById('sec-'+p)) goPage(p); };\n"
              "  fromHash(); window.addEventListener('hashchange', fromHash);\n"
              "})();\n", where='app')

    # ---------------------------------------------------------------- vocabulary (markup + app)
    def relabel(t, where):
        t = t.replace('Medicat ', '').replace('Medicat', '')
        t = t.replace('Dekalb Pediatric Center', '__LRN_LAB_NAME__').replace("Dekalb's", "__LRN_LAB_NAME__'s").replace('Dekalb', '__LRN_LAB_NAME__')
        pairs = [
            ('External Number', 'Claim ID'), ('external number', 'claim ID'),
            ('Patient UID', 'Patient ID'),
            ('First Filed Date', 'First Billed Date'), ('Last Filed Date', 'Last Billed Date'),
            ("short:'Filed'", "short:'Billed'"), ("'first filed'", "'first billed'"),
            ('Insurance Code', 'Payer Code'), ('Insurance Name', 'Payer Name'),
            ('Insurance Group', 'Payer Type'), ('insurance group', 'payer type'), ('Insurance group', 'Payer type'),
            ('Order Type', 'Panel'), ('order type', 'panel'), ('Order type', 'Panel'), ('ORDER TYPE', 'PANEL'),
            ('Billing Provider', 'Clinic'), ('billing provider', 'clinic'), ('Billing provider', 'Clinic'),
            ('Rendering Provider', 'Referring Provider'), ('rendering provider', 'referring provider'),
            ('Rendering provider', 'Referring provider'),
            ('Billing vs Rendering', 'Clinic vs Referring Provider'),
            ('rendered by', 'referred by'),
        ]
        for a, b in pairs:
            t = t.replace(a, b)
        return t

    markup = relabel(markup, 'markup')
    app = relabel(app, 'app')
    for word in ('Dekalb', 'Medicat', 'Superior Billing'):
        if word in markup or word in app or word in head:
            fail(f'{word!r} still present after conversion')

    out_html = head + chartjs + markup + blobs + app
    for token in ('__LRN_DATA_BLOB__', '__LRN_LINE_BLOB__', '__LRN_LINEEXPORT_BLOB__', '__LRN_LAB_NAME__', '__LRN_GEN_DAY__',
                  '__LRN_GENERATED__', '__LRN_VALID_FROM__', '__LRN_PERIOD__', '__LRN_CPT_INFO__', '__LRN_FILE_TAG__',
                  '__LRN_SOURCE_LABEL__', '__LRN_SOURCE_SHORT__'):
        if token not in out_html:
            fail('placeholder missing from output: ' + token)

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write(out_html)
    print(f'wrote {out} ({len(out_html):,} chars)')


if __name__ == '__main__':
    main()
