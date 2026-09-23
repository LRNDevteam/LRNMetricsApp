(() => {
    const activeTabInput = document.getElementById("activeTabInput");
    const tabButtons = document.querySelectorAll('#dashboardTabs button[data-bs-toggle="pill"]');

    tabButtons.forEach((button) => {
        button.addEventListener("shown.bs.tab", (event) => {
            const target = event.target.getAttribute("data-bs-target");
            if (target && activeTabInput) {
                activeTabInput.value = target.replace("#", "");
            }
        });
    });

    document.querySelectorAll(".table-search-input").forEach((input) => {
        input.addEventListener("input", () => {
            const tableId = input.getAttribute("data-target-table");
            const table = document.getElementById(tableId);
            if (!table) {
                return;
            }

            const searchText = input.value.trim().toLowerCase();
            const rows = table.querySelectorAll("tbody tr");
            rows.forEach((row) => {
                const text = row.innerText.toLowerCase();
                row.style.display = text.includes(searchText) ? "" : "none";
            });
        });
    });

    document.querySelectorAll(".accordion-search-input").forEach((input) => {
        input.addEventListener("input", () => {
            const accordionId = input.getAttribute("data-target-accordion");
            const accordion = document.getElementById(accordionId);
            if (!accordion) {
                return;
            }

            const searchText = input.value.trim().toLowerCase();
            const items = accordion.querySelectorAll(".claim-group-item");

            items.forEach((item) => {
                const text = item.innerText.toLowerCase();
                item.style.display = text.includes(searchText) ? "" : "none";
            });
        });
    });

    const charts = window.dashboardCharts;
    if (charts && typeof Chart !== "undefined") {
        const defaultPalette = [
            "rgba(27, 42, 74, 0.85)",
            "rgba(46, 95, 163, 0.85)",
            "rgba(25, 135, 84, 0.85)",
            "rgba(245, 159, 0, 0.85)",
            "rgba(220, 53, 69, 0.85)",
            "rgba(142, 68, 173, 0.85)",
            "rgba(13, 202, 240, 0.85)"
        ];

        const buildChart = (canvasId, type, dataObject) => {
            const canvas = document.getElementById(canvasId);
            if (!canvas || !dataObject) {
                return;
            }

            const labels = Object.keys(dataObject);
            const values = Object.values(dataObject);

            new Chart(canvas, {
                type,
                data: {
                    labels,
                    datasets: [{
                        data: values,
                        backgroundColor: defaultPalette,
                        borderWidth: 0,
                        borderRadius: type === "bar" ? 10 : 0
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            display: type !== "bar",
                            position: "bottom"
                        }
                    },
                    scales: type === "bar"
                        ? {
                            x: {
                                grid: { display: false }
                            },
                            y: {
                                beginAtZero: true,
                                ticks: { precision: 0 }
                            }
                        }
                        : {}
                }
            });
        };

        buildChart("statusChart", "bar", charts.status);
        buildChart("priorityChart", "doughnut", charts.priority);
    }
})();

(() => {
    const label = (open) => open ? "\u25B2 Hide" : "\u25BC Show";
    document.querySelectorAll("[data-rpt-filter-toggle]").forEach((btn) => {
        const sel = btn.getAttribute("data-bs-target");
        const target = sel ? document.querySelector(sel) : null;
        if (!target) return;
        const sync = () => { btn.textContent = label(target.classList.contains("show")); };
        target.addEventListener("shown.bs.collapse", sync);
        target.addEventListener("hidden.bs.collapse", sync);
        sync();
    });
})();

window.rptExportBusy = function (btn, html) {
    if (!btn) return;
    btn.classList.add("rpt-toolbar-busy");
    btn.innerHTML = html;
};
window.rptExportIdle = function (btn, originalHtml) {
    if (!btn) return;
    btn.classList.remove("rpt-toolbar-busy");
    if (typeof originalHtml === "string") btn.innerHTML = originalHtml;
    btn.disabled = false;
};

/* Collection Summary: Avg Payments headers, Panel vs Payment footer, Status Summary widths + expand. */
(function () {
    if (!document.getElementById("cs-avgpay-mcv-css")) {
        var el = document.createElement("style");
        el.id = "cs-avgpay-mcv-css";
        el.textContent =
            "html body div#avgpay-pane table.cs-pr-table[class] thead tr th[class]," +
            "html body div#avgpay3-pane table.cs-pr-table[class] thead tr th[class]," +
            "html body div#avgpay-pane table.cs-pr-table[class] thead tr th," +
            "html body div#avgpay3-pane table.cs-pr-table[class] thead tr th" +
            "{background:#0e3460 !important;background-color:#0e3460 !important;background-image:none !important;" +
            "color:#ffffff !important;-webkit-text-fill-color:#ffffff !important;}" +
            "html body div#avgpay-pane table.cs-pr-table[class] thead tr th.ap-grp[class]," +
            "html body div#avgpay3-pane table.cs-pr-table[class] thead tr th.ap-grp[class]" +
            "{background:linear-gradient(135deg,#0a1628 0%,#0e3460 50%,#0d5c74 100%) !important;" +
            "color:rgba(255,255,255,.92) !important;-webkit-text-fill-color:rgba(255,255,255,.92) !important;" +
            "top:0 !important;z-index:5 !important;}" +
            "html body #avgpay-pane .cs-pr-panel td,html body #avgpay3-pane .cs-pr-panel td" +
            "{background:#f0fdf4 !important;}" +
            "html body #avgpay-pane .cs-pr-panel td:first-child,html body #avgpay3-pane .cs-pr-panel td:first-child" +
            "{background:#f0fdf4 !important;color:#166534 !important;}" +
            /* Panel vs Payment: year/Grand Total footer cells = navy (not cream/peach) */
            "html body #panelpay-pane .cs-rpt-table tbody td.cs-pr-year{background-color:#fefce8 !important;}" +
            "html body #panelpay-pane .cs-rpt-table tbody td.cs-pr-grand{background-color:#fef3c7 !important;font-weight:800;}" +
            "html body #panelpay-pane .cs-rpt-table tfoot td," +
            "html body #panelpay-pane .cs-rpt-table tfoot td.cs-pr-year," +
            "html body #panelpay-pane .cs-rpt-table tfoot td.cs-pr-grand" +
            "{background:#0e3460 !important;color:#fff !important;font-weight:800;}" +
            /* Status Summary: fit columns to content */
            "html body #statussummary-pane #tblStatusSummary," +
            "html body #tblStatusSummary" +
            "{width:max-content !important;min-width:0 !important;table-layout:auto !important;}" +
            "html body #tblStatusSummary thead th,html body #tblStatusSummary td" +
            "{white-space:nowrap;width:auto;min-width:0;}";
        document.body.appendChild(el);
    }

    function ssSetToggle(tbl, key, open) {
        var btn = tbl.querySelector('.ss-toggle[data-sskey="' + key + '"]');
        if (!btn) return;
        btn.textContent = open ? "\u2212" : "+";
        if (open) btn.classList.add("open"); else btn.classList.remove("open");
    }
    function ssCollapse(tbl, key) {
        tbl.querySelectorAll('tr[data-parent="' + key + '"]').forEach(function (child) {
            child.style.display = "none";
            child.setAttribute("data-open", "0");
            var ck = child.getAttribute("data-sskey");
            if (ck) { ssSetToggle(tbl, ck, false); ssCollapse(tbl, ck); }
        });
    }
    document.addEventListener("click", function (e) {
        var tr = e.target.closest && e.target.closest("#tblStatusSummary tr.ss-lvl1, #tblStatusSummary tr.ss-lvl2, #tblStatusSummary tr.ss-lvl3");
        if (!tr) return;
        var tbl = tr.closest("#tblStatusSummary");
        if (!tbl) return;
        var key = tr.getAttribute("data-sskey");
        if (!key) return;
        var kids = tbl.querySelectorAll('tr[data-parent="' + key + '"]');
        if (!kids.length) return;
        var open = tr.getAttribute("data-open") === "1";
        if (open) {
            ssCollapse(tbl, key);
            tr.setAttribute("data-open", "0");
            ssSetToggle(tbl, key, false);
        } else {
            kids.forEach(function (c) { c.style.display = ""; });
            tr.setAttribute("data-open", "1");
            ssSetToggle(tbl, key, true);
        }
    });
})();
