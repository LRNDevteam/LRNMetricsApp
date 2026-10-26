// Executive Summary value popup: clicking a value shows the source rows behind it
// and the rules that select them. Cells are rendered as
// a.es-cell-link (data-es-cat / -row / -title / -year / -month); the page filters,
// lab and endpoints come from #esCellCtx, which travels with the lazily loaded table.
(function () {
    var modalEl = document.getElementById('esCellModal');
    if (!modalEl) return;

    // bootstrap.bundle loads after the page body, so the instance is created on first use.
    var modal = null;
    function getModal() {
        return modal || (modal = bootstrap.Modal.getOrCreateInstance(modalEl));
    }
    var el = function (id) { return document.getElementById(id); };
    var MONTHS = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    var MONEY_COLS = { Amount: 1, ChargeAmount: 1, InsurancePayment: 1, PatientPayment: 1, PatientBalance: 1, TotalAdjustments: 1, TotalInsuranceBalance: 1,
                       InsuranceAdjustments: 1, PatientAdjustments: 1, InsuranceBalance: 1, ExpectedPayment: 1, TotalPayments: 1,
                       TotalCharge: 1, CarrierPayment: 1 };
    var PAGE_SIZE = 100;
    var current = null;
    var requestSeq = 0;

    function esc(s) {
        return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
            return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
        });
    }
    function money(n) {
        var v = Number(n || 0);
        var s = Math.abs(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
        return v < 0 ? '($' + s + ')' : '$' + s;
    }
    function count(n) { return Number(n || 0).toLocaleString('en-US'); }
    function periodLabel(y, m) {
        if (!y) return 'Grand Total';
        if (!m) return y + ' Total';
        return MONTHS[m] + ' ' + y;
    }
    function query(extra) {
        var ctx = el('esCellCtx');
        var parts = ['lab=' + encodeURIComponent(ctx.dataset.lab || '')];
        if (ctx.dataset.filters) parts.push(ctx.dataset.filters);
        Object.keys(extra).forEach(function (k) {
            if (extra[k] !== null && extra[k] !== undefined && extra[k] !== '')
                parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(extra[k]));
        });
        return parts.join('&');
    }

    function showAlert(msg) {
        var a = el('esCellAlert');
        a.textContent = msg || '';
        a.hidden = !msg;
    }

    var RULE_STYLE = {
        'source':      { icon: 'bi-database',       cls: 'esc-rule-source' },
        'base filter': { icon: 'bi-funnel',         cls: 'esc-rule-base' },
        'period':      { icon: 'bi-calendar3',      cls: 'esc-rule-period' },
        'row rule':    { icon: 'bi-list-ul',        cls: 'esc-rule-row' },
        'formula':     { icon: 'bi-calculator',     cls: 'esc-rule-row' },
        'measure':     { icon: 'bi-bar-chart-fill', cls: 'esc-rule-measure' },
        'page filter': { icon: 'bi-sliders',        cls: 'esc-rule-filter' },
        'calculation': { icon: 'bi-123',            cls: 'esc-rule-calc' }
    };

    function renderRules(rules) {
        var list = el('esCellRules');
        list.innerHTML = (rules || []).map(function (r) {
            var s = RULE_STYLE[String(r.group || '').toLowerCase()] || { icon: 'bi-info-circle', cls: '' };
            return '<li class="esc-rule ' + s.cls + '" tabindex="0" aria-expanded="false" title="' + esc(r.text) + '">' +
                '<span class="esc-rule-icon"><i class="bi ' + s.icon + '"></i></span>' +
                '<span class="esc-rule-body"><span class="esc-rule-label">' + esc(r.group) + '</span>' +
                '<span class="esc-rule-text">' + esc(r.text) + '</span></span>' +
                '<i class="bi bi-chevron-down esc-rule-chev" aria-hidden="true"></i></li>';
        }).join('');
        // Only cards whose text is clipped can expand.
        list.querySelectorAll('.esc-rule').forEach(function (li) {
            var t = li.querySelector('.esc-rule-text');
            if (t.scrollHeight <= t.clientHeight + 1) li.classList.add('esc-rule-fits');
        });
    }

    function toggleRule(li) {
        if (li.classList.contains('esc-rule-fits')) return;
        var open = li.classList.toggle('is-open');
        li.setAttribute('aria-expanded', open ? 'true' : 'false');
    }

    function gridNumber() {
        var t = (current.valueText || '').trim();
        return Number(t.replace(/[$,\s]/g, '').replace(/^\((.*)\)$/, '-$1'));
    }

    function renderSummary(res) {
        var box = el('esCellSummary');
        var gridText = (current.valueText || '').trim();
        if (res.isFormula) {
            var isMoneyResult = current.cat === 'Avg';
            var ok = Math.abs(gridNumber() - Number(res.totalAmount)) < 0.005;
            box.className = 'esc-summary ' + (ok ? 'esc-summary-ok' : 'esc-summary-warn');
            box.innerHTML =
                '<span><i class="bi bi-calculator"></i> Calculated from the rows below</span>' +
                '<span>Result: <strong>' + (isMoneyResult ? money(res.totalAmount) : count(res.totalAmount)) + '</strong></span>' +
                '<span>Grid value: <strong>' + esc(gridText) + '</strong></span>' +
                '<span class="esc-match">' + (ok
                    ? '<i class="bi bi-check-circle-fill"></i> Calculation equals the grid value'
                    : '<i class="bi bi-exclamation-triangle-fill"></i> Calculation differs from the grid value') + '</span>';
            return;
        }
        var isAmount = !!res.amountColumn;
        var found = isAmount ? money(res.totalAmount) : count(res.totalRows);
        var gridNum = gridNumber();
        var foundNum = isAmount ? Number(res.totalAmount) : Number(res.totalRows);
        var matches = !isNaN(gridNum) && Math.abs(gridNum - foundNum) < 0.005;
        box.className = 'esc-summary ' + (matches ? 'esc-summary-ok' : 'esc-summary-warn');
        box.innerHTML =
            '<span><strong>' + count(res.totalRows) + '</strong> ' + (res.sourceTable === 'dbo.LIMSMaster' ? 'samples' : 'claims') + '</span>' +
            (isAmount ? '<span>' + esc(res.measure) + ': <strong>' + found + '</strong></span>' : '') +
            '<span>Grid value: <strong>' + esc(gridText) + '</strong></span>' +
            '<span class="esc-match">' + (matches
                ? '<i class="bi bi-check-circle-fill"></i> Rows add up to the grid value'
                : '<i class="bi bi-exclamation-triangle-fill"></i> Rows differ from the grid value - the summary may need a refresh') + '</span>';
    }

    var SECTION_TITLE = {
        'Calculation': 'Calculation',
        'Numerator': 'Numerator - Total payments',
        'Denominator': 'Denominator - Claims',
        'Result': 'Result'
    };

    // Formula rows: the components with their values; each component opens its own rows.
    function renderBreakdown(res) {
        var table = el('esCellGrid');
        var idx = {};
        res.columns.forEach(function (c, i) { idx[c] = i; });
        var get = function (r, c) { return r[idx[c]]; };
        table.classList.add('esc-breakdown');
        table.tHead.innerHTML = '<tr><th class="esc-op"></th><th>Component</th><th class="esc-num">Value</th><th></th></tr>';
        var lastSection = null;
        table.tBodies[0].innerHTML = res.rows.map(function (r) {
            var section = get(r, 'Section');
            var isTotal = !!get(r, 'IsTotal');
            var isResult = section === 'Result';
            var val = get(r, 'IsMoney') ? money(get(r, 'Value')) : count(get(r, 'Value'));
            var rowCode = get(r, 'RowCode');
            var cat = get(r, 'Category');
            var canOpen = rowCode && !isResult && cat !== 'Avg';
            var head = '';
            if (section !== lastSection && !isResult) {
                head = '<tr class="esc-bd-section"><td colspan="4">' + esc(SECTION_TITLE[section] || section) + '</td></tr>';
            }
            lastSection = section;
            var cls = isResult ? 'esc-bd-result' : isTotal ? 'esc-bd-total' : 'esc-bd-item';
            return head + '<tr class="' + cls + '">' +
                '<td class="esc-op">' + esc(get(r, 'Operator')) + '</td>' +
                '<td>' + esc(get(r, 'Component')) + (rowCode && !isResult ? ' <span class="esc-bd-code">' + esc(cat + ' ' + rowCode) + '</span>' : '') + '</td>' +
                '<td class="esc-num">' + val + '</td>' +
                '<td class="esc-bd-action">' + (canOpen
                    ? '<a href="#" class="esc-comp-link" data-es-cat="' + esc(cat) + '" data-es-row="' + esc(rowCode) + '" data-es-title="' + esc(get(r, 'Component')) +
                      '" data-es-year="' + current.year + '" data-es-month="' + current.month + '" data-es-value="' + esc(val) + '"><i class="bi bi-table"></i> View rows</a>'
                    : '') + '</td></tr>';
        }).join('');
    }

    function renderGrid(res) {
        var table = el('esCellGrid');
        var wrap = el('esCellGridWrap');
        table.classList.remove('esc-breakdown');
        if (!res.columns || !res.columns.length) {
            wrap.hidden = true;
            return;
        }
        wrap.hidden = false;
        if (res.isFormula) {
            renderBreakdown(res);
            return;
        }
        var cols = res.columns;
        table.tHead.innerHTML = '<tr><th class="esc-rownum">#</th>' + cols.map(function (c) {
            return '<th' + (MONEY_COLS[c] ? ' class="esc-num"' : '') + (c === 'Amount' ? ' title="' + esc(res.amountColumn) + '"' : '') + '>' +
                esc(c === 'Amount' ? res.amountColumn + ' (measured)' : c) + '</th>';
        }).join('') + '</tr>';
        var start = (res.page - 1) * res.pageSize;
        table.tBodies[0].innerHTML = res.rows.length
            ? res.rows.map(function (r, i) {
                return '<tr><td class="esc-rownum">' + (start + i + 1) + '</td>' + r.map(function (v, ci) {
                    var c = cols[ci];
                    if (MONEY_COLS[c]) return '<td class="esc-num' + (c === 'Amount' ? ' esc-measured' : '') + '">' + (v === null ? '' : money(v)) + '</td>';
                    return '<td>' + esc(v) + '</td>';
                }).join('') + '</tr>';
            }).join('')
            : '<tr><td colspan="' + (cols.length + 1) + '" class="esc-empty">No rows.</td></tr>';
    }

    function renderPager(res) {
        var pager = el('esCellPager');
        if (res.isFormula || !res.totalRows) { pager.innerHTML = ''; return; }
        var pages = Math.max(1, Math.ceil(res.totalRows / res.pageSize));
        var from = (res.page - 1) * res.pageSize + 1;
        var to = Math.min(res.totalRows, res.page * res.pageSize);
        pager.innerHTML =
            '<button type="button" class="btn btn-sm btn-outline-secondary" data-esc-page="' + (res.page - 1) + '"' + (res.page <= 1 ? ' disabled' : '') + '>&lsaquo; Prev</button>' +
            '<span>Rows ' + count(from) + ' - ' + count(to) + ' of ' + count(res.totalRows) + ' (page ' + res.page + ' of ' + pages + ')</span>' +
            '<button type="button" class="btn btn-sm btn-outline-secondary" data-esc-page="' + (res.page + 1) + '"' + (res.page >= pages ? ' disabled' : '') + '>Next &rsaquo;</button>';
    }

    function load(page) {
        var ctx = el('esCellCtx');
        if (!ctx || !current) return;
        var seq = ++requestSeq;
        showAlert('');
        el('esCellLoading').hidden = false;
        el('esCellGridWrap').classList.add('esc-dim');
        var url = ctx.dataset.rowsUrl + '?' + query({
            category: current.cat, rowCode: current.row, year: current.year, month: current.month,
            page: page, pageSize: PAGE_SIZE
        });
        fetch(url, { credentials: 'same-origin', headers: { 'Accept': 'application/json' } })
            .then(function (r) {
                return r.json().catch(function () { return {}; }).then(function (body) {
                    if (!r.ok) throw new Error(body.error || ('Request failed (' + r.status + ').'));
                    return body;
                });
            })
            .then(function (res) {
                if (seq !== requestSeq) return;
                renderRules(res.rules);
                renderSummary(res);
                renderGrid(res);
                renderPager(res);
            })
            .catch(function (err) {
                if (seq !== requestSeq) return;
                showAlert(err.message || 'The rows for this value could not be loaded.');
            })
            .finally(function () {
                if (seq !== requestSeq) return;
                el('esCellLoading').hidden = true;
                el('esCellGridWrap').classList.remove('esc-dim');
            });
    }

    // Views opened from a formula breakdown, so Back returns to the formula.
    var backStack = [];

    function cellFromLink(link) {
        return {
            cat: link.dataset.esCat,
            row: link.dataset.esRow,
            title: link.dataset.esTitle || link.dataset.esRow,
            year: parseInt(link.dataset.esYear || '0', 10) || 0,
            month: parseInt(link.dataset.esMonth || '0', 10) || 0,
            valueText: link.dataset.esValue || link.textContent
        };
    }

    function open(cell) {
        var ctx = el('esCellCtx');
        if (!ctx) return;
        current = cell;
        el('esCellBack').hidden = backStack.length === 0;
        el('esCellModalTitle').textContent = current.title;
        el('esCellModalSub').textContent = current.cat + ' Breakdown · ' + periodLabel(current.year, current.month);
        el('esCellModalValue').textContent = current.valueText.trim();
        el('esCellRules').innerHTML = '';
        el('esCellSummary').innerHTML = '';
        el('esCellSummary').className = 'esc-summary';
        el('esCellGrid').tHead.innerHTML = '';
        el('esCellGrid').tBodies[0].innerHTML = '';
        el('esCellPager').innerHTML = '';

        getModal().show();
        load(1);
    }

    document.addEventListener('click', function (e) {
        var link = e.target.closest && e.target.closest('a.es-cell-link');
        if (link) {
            e.preventDefault();
            backStack = [];
            open(cellFromLink(link));
            return;
        }
        var comp = e.target.closest && e.target.closest('a.esc-comp-link');
        if (comp) {
            e.preventDefault();
            backStack.push(current);
            open(cellFromLink(comp));
            return;
        }
        if (e.target.closest && e.target.closest('#esCellBack')) {
            e.preventDefault();
            if (backStack.length) open(backStack.pop());
            return;
        }
        var pageBtn = e.target.closest && e.target.closest('#esCellPager [data-esc-page]');
        if (pageBtn && !pageBtn.disabled) {
            load(parseInt(pageBtn.getAttribute('data-esc-page'), 10) || 1);
            return;
        }
        var rule = e.target.closest && e.target.closest('#esCellRules .esc-rule');
        if (rule) toggleRule(rule);
    });

    document.addEventListener('keydown', function (e) {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        var rule = e.target.closest && e.target.closest('#esCellRules .esc-rule');
        if (rule) { e.preventDefault(); toggleRule(rule); }
    });
})();
