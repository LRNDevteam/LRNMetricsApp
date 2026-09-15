/* Production / LIS / Collection Insights panel. Reads #riRoot data-* and
   talks to NotesController. Screen 5 Active Note Detail matches the client
   View/Edit mockup (context, audit, revision history, archive). */
(function () {
    "use strict";
    const root = document.getElementById("riRoot");
    if (!root) return;

    function parseWeekRange(text) {
        const out = { start: "", end: "" };
        if (!text) return out;
        const toIso = s => {
            s = String(s || "").trim();
            let m = s.match(/^(\d{1,2})[.\/](\d{1,2})[.\/](\d{4})$/);
            if (m) return `${m[3]}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}`;
            m = s.match(/^(\d{1,2})[.\/](\d{1,2})[.\/](\d{2})$/);
            if (m) {
                const yy = parseInt(m[3], 10);
                const year = yy >= 70 ? 1900 + yy : 2000 + yy;
                return `${year}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}`;
            }
            m = s.match(/^(\d{4})[-.\/](\d{1,2})[-.\/](\d{1,2})$/);
            if (m) return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
            const d = new Date(s);
            return isNaN(d) ? "" : d.toISOString().slice(0, 10);
        };
        const tokens = String(text).match(/\d{4}-\d{1,2}-\d{1,2}|\d{1,2}[.\/]\d{1,2}[.\/]\d{2,4}/g) || [];
        if (tokens.length >= 2) {
            out.start = toIso(tokens[0]);
            out.end = toIso(tokens[tokens.length - 1]);
            return out;
        }
        if (tokens.length === 1) {
            out.start = out.end = toIso(tokens[0]);
            return out;
        }
        const parts = String(text).split(/\s+[-–—]\s+|\s+to\s+/i).filter(Boolean);
        if (parts.length >= 2) { out.start = toIso(parts[0]); out.end = toIso(parts[1]); }
        else if (parts.length === 1) out.start = out.end = toIso(parts[0]);
        return out;
    }

    const wk = parseWeekRange(root.dataset.weekText || "");
    const ctx = {
        lab: root.dataset.lab || "",
        reportName: root.dataset.reportName || "Production Report",
        runId: root.dataset.runId || "",
        weekText: root.dataset.weekText || "",
        weekStart: root.dataset.weekStart || wk.start || "",
        weekEnd: root.dataset.weekEnd || wk.end || wk.start || "",
        token: (root.querySelector('input[name="__RequestVerificationToken"]') || {}).value || ""
    };
    const apiBase = (root.dataset.base || "/").replace(/\/$/, "");
    const q = obj => Object.entries(obj).filter(([, v]) => v != null && v !== "").map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v)).join("&");
    const esc = s => (s == null ? "" : String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])));
    const isoDate = s => { if (!s) return ""; const d = new Date(s); return isNaN(d) ? "" : d.toISOString().slice(0, 10); };
    const MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    const fmtShort = s => {
        if (!s) return "";
        const d = new Date(s);
        if (isNaN(d)) return "";
        return d.getDate() + "-" + MONTHS[d.getMonth()];
    };
    const fmtDT = s => { if (!s) return ""; const d = new Date(s); return isNaN(d) ? "" : d.toLocaleString(); };
    const stripHtml = s => { if (!s) return ""; const d = document.createElement("div"); d.innerHTML = s; return (d.textContent || d.innerText || "").trim(); };
    const htmlFromText = s => {
        if (!s) return "";
        if (/<[a-z][\s\S]*>/i.test(s)) return s;
        return esc(s).replace(/\n/g, "<br>");
    };

    function reportLayout() {
        const r = (ctx.reportName || "").toLowerCase();
        if (r.includes("collection")) {
            return {
                claims: "# of Cases", charge: "Total Bill", data: "Case Link",
                action: "Action / Solution / Suggestion", owner: "Response By",
                footer: "Previously Analysed Data - Pending Items",
                footerSub: "(Refer Old Reports for Data Links)"
            };
        }
        if (r.includes("lis")) {
            return {
                claims: "# of Claims", charge: "Expected Reimbursement ($)", data: "Data Link",
                action: "Action / Solution / Suggestions", owner: "Responsibility",
                footer: "Previously Analyzed Data - All Data",
                footerSub: "(Refer Old Reports for Data Links)"
            };
        }
        return {
            claims: "# of Claims", charge: "Total Charge", data: "Data",
            action: "Action / Solution / Suggestions", owner: "Responsibility",
            footer: "Previously Analysed Data - Pending Items",
            footerSub: "(Refer Old Reports for Data Links)"
        };
    }

    const el = {
        body: document.getElementById("riBody"),
        alert: document.getElementById("riAlert"),
        tpl: document.getElementById("riTemplate"),
        add: document.getElementById("riAddBtn"),
        archiveBtn: document.getElementById("riArchiveBtn"),
        form: document.getElementById("riForm"),
        save: document.getElementById("riSaveBtn"),
        historyBtn: document.getElementById("riHistoryBtn"),
        title: document.getElementById("riModalTitle"),
        sub: document.getElementById("riModalSub"),
        versionNote: document.getElementById("riVersionNote"),
        riskBadge: document.getElementById("riRiskBadge"),
        statusBadge: document.getElementById("riStatusBadge"),
        activeBadge: document.getElementById("riActiveBadge"),
        historyTimeline: document.getElementById("riHistoryTimeline"),
        historySummary: document.getElementById("riHistorySummary"),
        historyNoteBadge: document.getElementById("riHistoryNoteBadge"),
        archiveBody: document.getElementById("riArchiveBody"),
        expandBtn: document.getElementById("riExpandBtn"),
        expandBody: document.getElementById("riExpandBody"),
        floatWin: document.getElementById("riFloat"),
        minimizeBtn: document.getElementById("riMinimizeBtn")
    };

    let lookups = { risks: [], statuses: [], responsibleParties: [] };
    let templates = [];
    let selectedTpl = null;
    let rows = [];
    let editing = null;
    let detailReadOnly = false;
    let dirty = false;
    let modal = null;
    let historyModal = null;
    let archiveModal = null;

    function showAlert(msg, kind) {
        if (!el.alert) return;
        el.alert.hidden = !msg;
        el.alert.className = "itm-alert " + (kind || "info");
        el.alert.textContent = msg || "";
    }

    async function api(path, opts) {
        const res = await fetch(path, opts);
        if (!res.ok) {
            let msg = "Request failed (" + res.status + ")";
            try { const j = await res.json(); if (j && j.error) msg = j.error; } catch { /* ignore */ }
            throw new Error(msg);
        }
        return res.status === 204 ? null : res.json();
    }
    const getJson = path => api(path, { headers: { Accept: "application/json" } });
    const postJson = (path, body) => api(path, {
        method: "POST",
        headers: { "Content-Type": "application/json", Accept: "application/json", RequestVerificationToken: ctx.token },
        body: body ? JSON.stringify(body) : null
    });

    function fieldKey(col) {
        const k = (col.fieldKey || "").trim();
        if (k) return k;
        const n = (col.columnName || "").toLowerCase();
        if (n === "risk") return "Risk";
        if (n.includes("responsible party")) return "ResponsibleParty";
        if (n === "insights") return "Insights";
        if (n.includes("link") || n === "data") return "DataLink";
        if (n.includes("claim") || n.includes("sample") || n.includes("case")) return "NoOfClaims";
        if (n.includes("charge") || n.includes("bill") || n.includes("reimbursement")) return "TotalCharge";
        if (n.includes("action")) return "ActionSolution";
        if (n.includes("feedback")) return "FeedbackResponse";
        if (n.includes("response by") || n === "responsibility") return "Responsibility";
        if (n.includes("discussion")) return "DiscussionDate";
        if (n === "eta") return "ETA";
        if (n.includes("closed")) return "ClosedDate";
        if (n === "status") return "Status";
        return col.columnName || "Text";
    }

    function riskCode(val) {
        const v = String(val || "").toLowerCase();
        if (v.startsWith("high") || v === "red") return "Red";
        if (v.startsWith("low") || v === "green") return "Green";
        return "Yellow";
    }
    function riskDisplay(n) {
        const label = (n.riskLabel || "").toLowerCase();
        if (label.startsWith("high")) return "High";
        if (label.startsWith("low")) return "Low";
        if (label.startsWith("medium")) return "Medium";
        if (n.riskCode === "Red") return "High";
        if (n.riskCode === "Green") return "Low";
        return "Medium";
    }
    function riskSelectValue(n) {
        if (!n) return "Red";
        return n.riskCode || riskCode(riskDisplay(n));
    }
    function statusCode(val) {
        const v = String(val || "").toLowerCase();
        if (v.includes("yet to discuss") || v === "discuss") return "Discuss";
        if (v.includes("progress") || v === "wip") return "WIP";
        if (v.includes("defer")) return "Deferred";
        if (v.includes("close")) return "Closed";
        const hit = (lookups.statuses || []).find(s => s.label.toLowerCase() === v || s.code.toLowerCase() === v);
        return hit ? hit.code : (val || "Open");
    }
    function statusCss(code) {
        const c = statusCode(code);
        if (c === "Closed") return "status-Closed";
        if (c === "WIP") return "status-WIP";
        if (c === "Deferred") return "status-Deferred";
        if (c === "Discuss") return "status-Discuss";
        return "status-Open";
    }

    function money(v) {
        if (v == null || v === "") return "";
        const n = Number(v);
        if (isNaN(n)) return esc(v);
        if (n === 0) return "$ -";
        const abs = Math.abs(n).toLocaleString(undefined, { maximumFractionDigits: 0 });
        return n < 0 ? "$ (" + abs + ")" : "$ " + abs;
    }

    function partyOptions(sel) {
        const list = lookups.responsibleParties || [];
        let found = false;
        let opts = `<option value="">— Select —</option>` + list.map(p => {
            if (p === sel) found = true;
            return `<option value="${esc(p)}" ${p === sel ? "selected" : ""}>${esc(p)}</option>`;
        }).join("");
        if (sel && !found) opts += `<option value="${esc(sel)}" selected>${esc(sel)}</option>`;
        return opts;
    }
    function riskOptions(sel) {
        const opts = (lookups.risks || []).length
            ? lookups.risks.map(r => ({ value: r.code, label: r.code + (r.label ? " — " + r.label : "") }))
            : [{ value: "Red", label: "Red — High" }, { value: "Yellow", label: "Yellow — Medium" }, { value: "Green", label: "Green — Low" }];
        return opts.map(o => `<option value="${esc(o.value)}" ${o.value === sel ? "selected" : ""}>${esc(o.label)}</option>`).join("");
    }
    function statusOptions(sel) {
        const opts = (lookups.statuses || []).length
            ? lookups.statuses
            : [{ code: "Discuss", label: "Yet to Discuss" }, { code: "Open", label: "Open" }, { code: "WIP", label: "In Progress" }, { code: "Deferred", label: "Deferred" }, { code: "Closed", label: "Closed" }];
        return opts.map(s => `<option value="${esc(s.code)}" ${s.code === sel ? "selected" : ""}>${esc(s.label || s.code)}</option>`).join("");
    }

    function bindRowActs(container) {
        if (!container) return;
        container.querySelectorAll("[data-view]").forEach(btn => {
            btn.onclick = () => openDetail(rows.find(r => String(r.noteId) === btn.getAttribute("data-view")), false);
        });
        container.querySelectorAll("[data-hist]").forEach(btn => {
            btn.onclick = () => openHistory(+btn.getAttribute("data-hist"));
        });
    }

    function buildTableHtml(opts) {
        const float = !!(opts && opts.float);
        const L = reportLayout();
        const colCount = float ? 14 : 15;
        const thead = `<thead><tr>
            <th>#</th><th>Risk</th><th>Responsible Party</th><th class="ri-insights">Insights</th>
            <th>${esc(L.claims)}</th><th>${esc(L.charge)}</th><th>${esc(L.data)}</th>
            <th class="ri-action">${esc(L.action)}</th>
            <th>Feedback / Response</th><th>${esc(L.owner)}</th>
            <th>Discussion Date</th><th>ETA</th><th>Closed Date</th><th>Status</th>${float ? "" : "<th></th>"}
        </tr></thead>`;
        const tfoot = float ? "" : `<tfoot><tr class="ri-foot-row"><td colspan="${colCount}"><div class="ri-footer">${esc(L.footer)}<small>${esc(L.footerSub)}</small></div></td></tr></tfoot>`;
        return `<table class="ri-table">${thead}<tbody>${rows.map(n => {
            const risk = riskDisplay(n);
            const st = n.statusLabel || n.statusCode || "";
            const discuss = /yet to discuss|discuss/i.test(st);
            const link = n.dataLink ? `<a class="ri-link" href="${esc(n.dataLink)}" target="_blank" rel="noopener">Link</a>` : "";
            const carry = n.archiveStatus === "Carry Forward" ? `<span class="ri-carry">Carry Forward</span>` : "";
            const acts = float ? "" : `<td class="ri-row-acts">
                    <button type="button" class="btn btn-sm btn-outline-secondary" data-view="${n.noteId}">View</button>
                    <button type="button" class="btn btn-sm btn-outline-secondary" data-hist="${n.noteId}">History</button>
                </td>`;
            return `<tr>
                <td>${esc(n.entryNo ?? "")}${carry}</td>
                <td class="ri-risk-${esc(risk)}">${esc(risk)}</td>
                <td>${esc(n.responsibleParty || "")}</td>
                <td class="ri-insights">${esc(stripHtml(n.insights || ""))}</td>
                <td class="ri-count">${esc(n.noOfSamples ?? "")}</td>
                <td class="ri-charge">${n.totalCharge == null || n.totalCharge === "" ? "" : money(n.totalCharge)}</td>
                <td>${link}</td>
                <td class="ri-action-cell">${esc(stripHtml(n.actionSolution || ""))}</td>
                <td>${esc(stripHtml(n.feedbackResponse || ""))}</td>
                <td>${esc(n.responsibility || "")}</td>
                <td>${esc(fmtShort(n.discussionDate))}</td>
                <td>${esc(fmtShort(n.eta))}</td>
                <td>${esc(fmtShort(n.closedDate))}</td>
                <td class="${discuss ? "ri-status-discuss" : ""}">${esc(st)}</td>
                ${acts}
            </tr>`;
        }).join("")}</tbody>${tfoot}</table>`;
    }

    function emptyHtml() {
        return `<div class="ri-empty">No insights added for the current week range.</div>`;
    }

    function weekKey(s) {
        return String(s || "").replace(/\s+/g, " ").trim().toLowerCase();
    }

    function inCurrentWeek(n) {
        if (!ctx.weekStart && !ctx.weekText) return true;
        const hasStart = n && n.weekRangeStart != null && String(n.weekRangeStart) !== "";
        const hasText = !!(n && n.weekRangeText);
        if (!hasStart && !hasText) return true;
        if (ctx.weekStart && hasStart) {
            const raw = String(n.weekRangeStart);
            const ws = isoDate(n.weekRangeStart) || (raw.length >= 10 ? raw.slice(0, 10) : "");
            if (ws && ws === ctx.weekStart) return true;
        }
        if (ctx.weekText && hasText && weekKey(n.weekRangeText) === weekKey(ctx.weekText)) return true;
        return false;
    }

    function renderRows() {
        if (!rows.length) {
            const html = emptyHtml();
            el.body.innerHTML = html;
            if (el.expandBody) el.expandBody.innerHTML = html;
            return;
        }
        const html = buildTableHtml();
        el.body.innerHTML = html;
        bindRowActs(el.body);
        if (el.expandBody) el.expandBody.innerHTML = buildTableHtml({ float: true });
    }

    function setFloatOpen(open) {
        if (!el.floatWin) return;
        el.floatWin.classList.toggle("open", !!open);
        el.floatWin.hidden = !open;
        if (open) {
            el.expandBody.innerHTML = rows.length ? buildTableHtml({ float: true }) : emptyHtml();
            el.floatWin.style.left = "50%";
            el.floatWin.style.top = "50%";
            el.floatWin.style.right = "auto";
            el.floatWin.style.bottom = "auto";
            el.floatWin.style.width = "";
            el.floatWin.style.transform = "translate(-50%, -50%)";
        }
    }

    function setDirty(on) {
        dirty = !!on;
        if (!el.versionNote) return;
        if (detailReadOnly) {
            el.versionNote.textContent = "Archived notes are read-only.";
            return;
        }
        if (!editing) {
            el.versionNote.textContent = dirty ? "Unsaved new insight. Click Save Changes to append to the active log." : "New insight. Save to assign Entry ID and version 1.";
            return;
        }
        const ver = editing.versionNumber || 1;
        el.versionNote.textContent = dirty
            ? `Unsaved changes. Click Save Changes to create v${ver + 1}.`
            : `Current version ${ver}. Save changes to create the next revision.`;
    }

    function syncBadges() {
        const risk = el.form.querySelector("[data-key=Risk]");
        const status = el.form.querySelector("[data-key=Status]");
        const code = risk ? risk.value : (editing ? riskSelectValue(editing) : "Red");
        const st = status ? status.value : (editing ? (editing.statusCode || "Open") : "Discuss");
        const stLabel = status && status.selectedOptions[0] ? status.selectedOptions[0].text : st;
        if (el.riskBadge) {
            el.riskBadge.textContent = code || "Risk";
            el.riskBadge.className = "ri-badge risk-" + (code || "Yellow");
        }
        if (el.statusBadge) {
            el.statusBadge.textContent = stLabel || "Status";
            el.statusBadge.className = "ri-badge " + statusCss(st);
        }
        const preview = el.form.querySelector("#riRiskPreview");
        if (preview) {
            preview.textContent = code || "Risk";
            preview.className = "ri-risk-preview ri-badge risk-" + (code || "Yellow");
        }
    }

    function bindRichToolbar(ro) {
        const editor = el.form.querySelector("#riInsightsEditor");
        if (!editor || ro) return;
        try { document.execCommand("styleWithCSS", false, true); } catch { /* ignore */ }
        el.form.querySelectorAll("[data-rich]").forEach(btn => {
            btn.onclick = () => {
                editor.focus();
                const cmd = btn.getAttribute("data-rich");
                if (cmd === "bold") document.execCommand("bold");
                else if (cmd === "list") document.execCommand("insertUnorderedList");
                else if (cmd === "Red") document.execCommand("foreColor", false, "#b42318");
                else if (cmd === "Yellow") document.execCommand("foreColor", false, "#9a6500");
                else if (cmd === "Green") document.execCommand("foreColor", false, "#2f7a4d");
                setDirty(true);
            };
        });
        const risk = el.form.querySelector("[data-key=Risk]");
        if (risk) {
            risk.addEventListener("change", () => {
                const map = { Red: "#b42318", Yellow: "#9a6500", Green: "#2f7a4d" };
                editor.focus();
                document.execCommand("foreColor", false, map[risk.value] || "#9a6500");
                syncBadges();
                setDirty(true);
            });
        }
    }

    function openDetail(row, archived) {
        editing = row || null;
        detailReadOnly = !!archived || (row && row.archiveStatus === "Archived");
        const L = reportLayout();
        const isNew = !row;
        if (el.title) el.title.textContent = isNew ? "Add Insight" : (detailReadOnly ? "Archived Note Detail" : "Active Note Detail");
        if (el.sub) el.sub.textContent = isNew
            ? "New insight · appended to the active log on save"
            : (detailReadOnly
                ? "Read-only historical insight · current report archive"
                : "Editable active insight · authorized report users");
        if (el.activeBadge) {
            el.activeBadge.textContent = detailReadOnly ? "Archived" : "Active";
            el.activeBadge.className = "ri-badge" + (detailReadOnly ? " archived" : "");
        }
        if (el.save) el.save.hidden = detailReadOnly;
        if (el.historyBtn) el.historyBtn.hidden = isNew;

        const ro = detailReadOnly ? "disabled" : "";
        const roAttr = detailReadOnly ? "readonly" : "";
        const editable = detailReadOnly ? "false" : "true";
        const banner = detailReadOnly
            ? `<div class="ri-lock-note"><span>Archived notes are read-only. This entry cannot be edited, deleted, saved, or reopened. Revision history remains available for audit.</span></div>`
            : `<div class="ri-edit-banner"><span>Active notes can be edited by authorized users with access to this report. Saving changes updates the active row, increments the version number, and records a revision event.</span></div>`;

        const week = (row && row.weekRangeText) || ctx.weekText || "—";
        const runId = (row && row.reportRunId) || ctx.runId || "—";
        const archiveLabel = detailReadOnly ? "Archived" : ((row && row.archiveStatus) || "Active");

        el.form.innerHTML = `
            ${banner}
            <div class="ri-ctx-row">
                <div class="ri-ctx-card"><div class="ri-ctx-label">Report Name</div><div class="ri-ctx-value">${esc(ctx.reportName)}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Week Range</div><div class="ri-ctx-value">${esc(week)}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Report ID / RUNID</div><div class="ri-ctx-value">${esc(runId)}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Archive Status</div><div class="ri-ctx-value">${esc(archiveLabel)}</div></div>
            </div>
            <div class="ri-detail-layout">
                <div class="ri-detail-col">
                    <section class="ri-info-card">
                        <div class="ri-info-head"><div class="ri-info-title">Insight</div><div class="ri-info-sub">Observation, risk, and impact reference</div></div>
                        <div class="ri-info-body">
                            <div class="ri-field-grid" style="margin-bottom:9px;">
                                <div class="ri-field">
                                    <label for="ri_Risk">Risk</label>
                                    <select id="ri_Risk" data-key="Risk" ${ro}>${riskOptions(riskSelectValue(row))}</select>
                                    <span id="riRiskPreview" class="ri-risk-preview">Risk</span>
                                </div>
                                <div class="ri-field">
                                    <label for="ri_ResponsibleParty">Responsible Party</label>
                                    <select id="ri_ResponsibleParty" data-key="ResponsibleParty" ${ro}>${partyOptions(row ? row.responsibleParty : "")}</select>
                                </div>
                                <div class="ri-field">
                                    <label for="ri_NoOfClaims">${esc(L.claims)}</label>
                                    <input id="ri_NoOfClaims" data-key="NoOfClaims" type="number" value="${esc(row && row.noOfSamples != null ? row.noOfSamples : "")}" ${roAttr} />
                                </div>
                                <div class="ri-field">
                                    <label for="ri_Status">Status</label>
                                    <select id="ri_Status" data-key="Status" ${ro}>${statusOptions(row ? (row.statusCode || "Open") : "Discuss")}</select>
                                </div>
                                <div class="ri-field">
                                    <label for="ri_TotalCharge">${esc(L.charge)}</label>
                                    <input id="ri_TotalCharge" data-key="TotalCharge" type="number" step="0.01" value="${esc(row && row.totalCharge != null ? row.totalCharge : "")}" ${roAttr} />
                                </div>
                                <div class="ri-field">
                                    <label for="ri_DataLink">${esc(L.data)}</label>
                                    <input id="ri_DataLink" data-key="DataLink" type="text" value="${esc(row ? (row.dataLink || "") : "")}" ${roAttr} />
                                </div>
                            </div>
                            <div class="ri-field">
                                <label>Insights</label>
                                <div class="ri-toolbar">
                                    <button class="ri-tool" type="button" data-rich="bold" ${detailReadOnly ? "disabled" : ""}>B</button>
                                    <button class="ri-tool" type="button" data-rich="list" ${detailReadOnly ? "disabled" : ""}>• List</button>
                                    <button class="ri-tool red" type="button" data-rich="Red" ${detailReadOnly ? "disabled" : ""}>Red</button>
                                    <button class="ri-tool yellow" type="button" data-rich="Yellow" ${detailReadOnly ? "disabled" : ""}>Yellow</button>
                                    <button class="ri-tool green" type="button" data-rich="Green" ${detailReadOnly ? "disabled" : ""}>Green</button>
                                    <span class="ri-info-sub">Risk color and inline highlight stay in sync.</span>
                                </div>
                                <div id="riInsightsEditor" class="ri-rich" contenteditable="${editable}" data-key="Insights">${htmlFromText(row ? row.insights : "")}</div>
                            </div>
                        </div>
                    </section>
                    <section class="ri-info-card">
                        <div class="ri-info-head"><div class="ri-info-title">Action and Response</div><div class="ri-info-sub">Follow-up plan and feedback</div></div>
                        <div class="ri-info-body">
                            <div class="ri-field" style="margin-bottom:9px;">
                                <label for="ri_ActionSolution">${esc(L.action)}</label>
                                <textarea id="ri_ActionSolution" data-key="ActionSolution" ${roAttr}>${esc(stripHtml(row ? row.actionSolution : ""))}</textarea>
                            </div>
                            <div class="ri-field-grid">
                                <div class="ri-field">
                                    <label for="ri_FeedbackResponse">Feedback / Response</label>
                                    <textarea id="ri_FeedbackResponse" data-key="FeedbackResponse" ${roAttr}>${esc(stripHtml(row ? row.feedbackResponse : ""))}</textarea>
                                </div>
                                <div class="ri-field">
                                    <label for="ri_Responsibility">${esc(L.owner)}</label>
                                    <select id="ri_Responsibility" data-key="Responsibility" ${ro}>${partyOptions(row ? row.responsibility : "")}</select>
                                </div>
                            </div>
                        </div>
                    </section>
                </div>
                <div class="ri-detail-col">
                    <section class="ri-info-card">
                        <div class="ri-info-head"><div class="ri-info-title">Timeline</div><div class="ri-info-sub">Discussion through close</div></div>
                        <div class="ri-info-body">
                            <div class="ri-field-grid">
                                <div class="ri-field"><label for="ri_DiscussionDate">Discussion Date</label><input id="ri_DiscussionDate" data-key="DiscussionDate" type="date" value="${esc(isoDate(row && row.discussionDate))}" ${roAttr} /></div>
                                <div class="ri-field"><label for="ri_ETA">ETA</label><input id="ri_ETA" data-key="ETA" type="date" value="${esc(isoDate(row && row.eta))}" ${roAttr} /></div>
                                <div class="ri-field"><label for="ri_ClosedDate">Closed Date</label><input id="ri_ClosedDate" data-key="ClosedDate" type="date" value="${esc(isoDate(row && row.closedDate))}" ${roAttr} /></div>
                                <div class="ri-field"><label>Archive Status</label><span class="ri-status-pill">${esc(archiveLabel)}</span></div>
                            </div>
                        </div>
                    </section>
                    <section class="ri-info-card">
                        <div class="ri-info-head"><div class="ri-info-title">Audit Metadata</div><div class="ri-info-sub">System-managed fields</div></div>
                        <div class="ri-info-body">
                            <div class="ri-field-grid">
                                <div class="ri-field"><label>Note / Entry ID</label><input readonly value="${esc(row ? (row.noteId || "") : "Assigned on save")}" /></div>
                                <div class="ri-field"><label>Version Number</label><input readonly value="${esc(row ? ("v" + (row.versionNumber || 1)) : "v1 (unsaved)")}" /></div>
                                <div class="ri-field"><label>Created By</label><input readonly value="${esc(row ? (row.createdBy || "") : "")}" /></div>
                                <div class="ri-field"><label>Created Date/Time</label><input readonly value="${esc(fmtDT(row && row.createdDateTime))}" /></div>
                                <div class="ri-field"><label>Last Edited By</label><input readonly value="${esc(row ? (row.lastEditedBy || "") : "")}" /></div>
                                <div class="ri-field"><label>Last Edited Date/Time</label><input readonly value="${esc(fmtDT(row && row.lastEditedDateTime))}" /></div>
                            </div>
                        </div>
                    </section>
                </div>
            </div>`;

        syncBadges();
        bindRichToolbar(detailReadOnly);
        el.form.querySelectorAll("input, select, textarea, [contenteditable]").forEach(node => {
            node.addEventListener("input", () => { setDirty(true); if (node.dataset && node.dataset.key === "Status") syncBadges(); });
            node.addEventListener("change", () => { setDirty(true); syncBadges(); });
        });
        setDirty(false);
        if (!modal && window.bootstrap) modal = new bootstrap.Modal(document.getElementById("riModal"));
        modal && modal.show();
    }

    function readForm() {
        const get = key => {
            if (key === "Insights") {
                const ed = el.form.querySelector("#riInsightsEditor");
                return ed ? ed.innerHTML.trim() : "";
            }
            const n = el.form.querySelector(`[data-key="${key}"]`);
            return n ? n.value.trim() : "";
        };
        const claims = get("NoOfClaims");
        const charge = get("TotalCharge");
        return {
            noteId: editing ? editing.noteId : null,
            reportName: ctx.reportName,
            reportRunId: (editing && editing.reportRunId) || ctx.runId || null,
            weekRangeText: (editing && editing.weekRangeText) || ctx.weekText || null,
            weekRangeStart: (editing && editing.weekRangeStart) || ctx.weekStart,
            weekRangeEnd: (editing && editing.weekRangeEnd) || ctx.weekEnd,
            riskCode: riskCode(get("Risk") || "Yellow"),
            responsibleParty: get("ResponsibleParty") || null,
            insights: get("Insights") || null,
            noOfSamples: claims === "" ? null : parseInt(claims, 10),
            totalCharge: charge === "" ? null : Number(charge),
            dataLink: get("DataLink") || null,
            actionSolution: get("ActionSolution") || null,
            feedbackResponse: get("FeedbackResponse") || null,
            responsibility: get("Responsibility") || null,
            discussionDate: get("DiscussionDate") || null,
            eta: get("ETA") || null,
            closedDate: get("ClosedDate") || null,
            statusCode: statusCode(get("Status") || "Discuss")
        };
    }

    async function save() {
        if (detailReadOnly) return;
        const payload = readForm();
        if (!stripHtml(payload.insights)) { alert("Insights is required."); return; }
        if (payload.statusCode === "Closed" && !payload.closedDate) {
            alert("Closed Date is required when Status is Closed.");
            return;
        }
        el.save.disabled = true;
        try {
            await postJson(`${apiBase}/Notes/Save?${q({ lab: ctx.lab, report: ctx.reportName })}`, payload);
            modal && modal.hide();
            await loadRows();
            showAlert("Insight saved. Version was incremented and a revision event was recorded.", "ok");
        } catch (e) { alert(e.message); }
        finally { el.save.disabled = false; }
    }

    async function openHistory(noteId, fromArchive) {
        if (!noteId) return;
        const note = rows.find(r => r.noteId === noteId);
        if (el.historyNoteBadge) el.historyNoteBadge.textContent = note ? ("#" + (note.entryNo || noteId)) : ("Note " + noteId);
        if (el.historySummary) {
            el.historySummary.innerHTML = `
                <div class="ri-ctx-card"><div class="ri-ctx-label">Note</div><div class="ri-ctx-value">${esc(note ? ("#" + (note.entryNo || noteId)) : noteId)}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Current Version</div><div class="ri-ctx-value">${esc(note ? ("v" + (note.versionNumber || 1)) : "—")}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Last Edited By</div><div class="ri-ctx-value">${esc(note ? (note.lastEditedBy || "—") : "—")}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Last Edited</div><div class="ri-ctx-value">${esc(fmtDT(note && note.lastEditedDateTime) || "—")}</div></div>`;
        }
        el.historyTimeline.innerHTML = `<div class="itm-empty">Loading revision history…</div>`;
        if (modal) modal.hide();
        if (!historyModal && window.bootstrap) historyModal = new bootstrap.Modal(document.getElementById("riHistoryModal"));
        historyModal && historyModal.show();
        try {
            const events = await getJson(`${apiBase}/Notes/Revisions?${q({ lab: ctx.lab, id: noteId })}`);
            if (!events.length) {
                el.historyTimeline.innerHTML = `<div class="itm-empty">No revision events recorded yet.</div>`;
                return;
            }
            el.historyTimeline.innerHTML = events.map(r => {
                const type = (r.eventType || "Edit").toLowerCase();
                const css = type.includes("status") ? "status" : type.includes("risk") ? "risk" : type.includes("archiv") ? "archive" : type.includes("creat") ? "create" : "";
                return `<div class="ri-rev">
                    <div class="ri-rev-dot">${esc((r.eventType || "E").slice(0, 1))}</div>
                    <div class="ri-rev-meta"><strong>${esc(fmtDT(r.eventDateTime) || "—")}</strong>User: ${esc(r.eventUser || "—")}</div>
                    <div class="ri-rev-card">
                        <div class="ri-rev-head"><span class="ri-rev-type ${css}">${esc(r.eventType || "Edit")}</span><span class="ri-version-note">v${esc(r.versionNumber)}</span></div>
                        <div class="ri-rev-change">Revision Made</div>
                        <div>${esc(r.revisionSummary || r.sourceAction || "")}</div>
                    </div>
                </div>`;
            }).join("");
        } catch (e) {
            el.historyTimeline.innerHTML = `<div class="itm-alert error">${esc(e.message)}</div>`;
        }
        const back = document.getElementById("riHistoryBackBtn");
        if (back) {
            back.onclick = () => {
                historyModal && historyModal.hide();
                if (fromArchive) {
                    archiveModal && archiveModal.show();
                    return;
                }
                if (editing && editing.noteId === noteId) modal && modal.show();
                else {
                    const row = rows.find(r => r.noteId === noteId);
                    if (row) openDetail(row, false);
                }
            };
        }
    }

    async function openArchive() {
        if (!archiveModal && window.bootstrap) archiveModal = new bootstrap.Modal(document.getElementById("riArchiveModal"));
        el.archiveBody.innerHTML = `<div class="itm-empty">Loading archive…</div>`;
        archiveModal && archiveModal.show();
        try {
            const data = await getJson(`${apiBase}/Notes/Archived?${q({ lab: ctx.lab, report: ctx.reportName })}`);
            const s = data.summary || {};
            const archived = data.rows || [];
            const cards = `<div class="ri-ctx-row">
                <div class="ri-ctx-card"><div class="ri-ctx-label">Total Archived</div><div class="ri-ctx-value">${esc(s.totalArchived || 0)}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Red Risk Archived</div><div class="ri-ctx-value">${esc(s.redRiskArchived || 0)}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Closed This Month</div><div class="ri-ctx-value">${esc(s.closedThisMonth || 0)}</div></div>
                <div class="ri-ctx-card"><div class="ri-ctx-label">Last Archived</div><div class="ri-ctx-value">${esc(fmtShort(s.lastArchivedDate) || "—")}</div></div>
            </div>
            <div class="ri-lock-note">Archived Notes are read-only. Closed entries older than 4 weeks cannot be edited. Open / WIP / Deferred items older than 4 weeks remain in Active Notes as carry-forward.</div>`;
            const table = archived.length ? `<table class="ri-archive-table"><thead><tr>
                <th>#</th><th>Week Range</th><th>Risk</th><th>Insights</th><th>Status</th><th>Closed</th><th></th>
            </tr></thead><tbody>${archived.map(n => `<tr>
                <td>${esc(n.entryNo ?? "")}</td>
                <td>${esc(n.weekRangeText || "")}</td>
                <td><span class="ri-badge risk-${esc(n.riskCode || "Yellow")}">${esc(n.riskCode || "")}</span></td>
                <td>${esc(stripHtml(n.insights || ""))}</td>
                <td>${esc(n.statusLabel || n.statusCode || "")}</td>
                <td>${esc(fmtShort(n.closedDate))}</td>
                <td class="ri-row-acts">
                    <button type="button" class="btn btn-sm btn-outline-secondary" data-aview="${n.noteId}">View</button>
                    <button type="button" class="btn btn-sm btn-outline-secondary" data-ahist="${n.noteId}">History</button>
                </td>
            </tr>`).join("")}</tbody></table>` : `<div class="itm-empty">No archived notes for this report.</div>`;
            el.archiveBody.innerHTML = cards + table;
            el.archiveBody.querySelectorAll("[data-aview]").forEach(btn => {
                btn.onclick = async () => {
                    const id = +btn.getAttribute("data-aview");
                    try {
                        const note = await getJson(`${apiBase}/Notes/Detail?${q({ lab: ctx.lab, id })}`);
                        archiveModal && archiveModal.hide();
                        openDetail(note, true);
                    } catch (e) { alert(e.message); }
                };
            });
            el.archiveBody.querySelectorAll("[data-ahist]").forEach(btn => {
                btn.onclick = () => openHistory(+btn.getAttribute("data-ahist"), true);
            });
        } catch (e) {
            el.archiveBody.innerHTML = `<div class="itm-alert error">${esc(e.message)}</div>`;
        }
    }

    function fillTemplates() {
        el.tpl.innerHTML = templates.map(t => `<option value="${t.templateId}">${esc(t.templateName)}</option>`).join("")
            || `<option value="">Key Insights & Highlights</option>`;
        if (templates.length === 1) {
            el.tpl.value = String(templates[0].templateId);
            selectedTpl = templates[0];
        } else if (templates.length > 1) {
            selectedTpl = templates.find(t => String(t.templateId) === el.tpl.value) || templates[0];
            el.tpl.value = String(selectedTpl.templateId);
        } else {
            selectedTpl = { templateName: "Key Insights & Highlights", columns: [] };
        }
    }

    async function loadRows() {
        const params = { lab: ctx.lab, report: ctx.reportName };
        if (ctx.weekStart) params.weekStart = ctx.weekStart;
        const data = await getJson(`${apiBase}/Notes/Active?${q(params)}`);
        const all = data.rows || [];
        rows = (ctx.weekStart || ctx.weekText) ? all.filter(inCurrentWeek) : all;
        renderRows();
    }

    let loadPromise = null;
    function showPanelLoading() {
        if (el.body) el.body.innerHTML = `<div class="ri-empty"><span class="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span> Loading insights…</div>`;
    }
    async function boot() {
        showPanelLoading();
        try {
            const avail = await getJson(`${apiBase}/Notes/Available?${q({ lab: ctx.lab })}`);
            if (!avail || !avail.available) {
                showAlert("Insights are not enabled for this lab yet. Run the NotesInsights SQL scripts on the lab database (CoveLRN), including 07 and 08.", "info");
                el.body.innerHTML = emptyHtml();
                el.add.disabled = true;
                if (el.archiveBtn) el.archiveBtn.disabled = true;
                return;
            }
            try { lookups = await getJson(`${apiBase}/Notes/Lookups?${q({ lab: ctx.lab })}`); }
            catch { /* defaults in form */ }
            try {
                const t = await getJson(`${apiBase}/Notes/Templates?${q({ lab: ctx.lab, report: ctx.reportName })}`);
                templates = t.templates || [];
            } catch { templates = []; }
            fillTemplates();
            await loadRows();
        } catch (e) {
            showAlert(e.message, "error");
            el.body.innerHTML = emptyHtml();
        }
    }
    function ensureLoaded() {
        if (!loadPromise) loadPromise = boot();
        return loadPromise;
    }

    el.tpl.addEventListener("change", () => {
        selectedTpl = templates.find(t => String(t.templateId) === el.tpl.value) || selectedTpl;
    });
    el.add.addEventListener("click", async () => {
        await ensureLoaded();
        openDetail(null, false);
    });
    el.save.addEventListener("click", save);
    if (el.archiveBtn) el.archiveBtn.addEventListener("click", () => { ensureLoaded().then(openArchive); });
    if (el.expandBtn) el.expandBtn.addEventListener("click", async () => {
        setOpen(true);
        await ensureLoaded();
        setFloatOpen(true);
    });
    if (el.minimizeBtn) el.minimizeBtn.addEventListener("click", () => setFloatOpen(false));
    (function enableFloatDrag() {
        const win = el.floatWin;
        const head = document.getElementById("riFloatHead");
        if (!win || !head) return;
        let drag = null;
        head.addEventListener("mousedown", function (e) {
            if (e.target.closest("button")) return;
            const r = win.getBoundingClientRect();
            drag = { x: e.clientX - r.left, y: e.clientY - r.top, w: r.width, h: r.height };
            win.style.transform = "none";
            win.style.left = r.left + "px";
            win.style.top = r.top + "px";
            win.style.right = "auto";
            win.style.bottom = "auto";
            win.style.width = r.width + "px";
            e.preventDefault();
        });
        document.addEventListener("mousemove", function (e) {
            if (!drag) return;
            const left = Math.max(8, Math.min(window.innerWidth - drag.w - 8, e.clientX - drag.x));
            const top = Math.max(8, Math.min(window.innerHeight - drag.h - 8, e.clientY - drag.y));
            win.style.left = left + "px";
            win.style.top = top + "px";
        });
        document.addEventListener("mouseup", function () { drag = null; });
    })();
    if (el.historyBtn) el.historyBtn.addEventListener("click", () => {
        if (editing && editing.noteId) openHistory(editing.noteId);
    });
    const extraAdd = document.getElementById("riAddInsightBtn");
    if (extraAdd) extraAdd.addEventListener("click", async () => {
        setOpen(true);
        root.scrollIntoView({ behavior: "smooth", block: "start" });
        await ensureLoaded();
        openDetail(null, false);
    });

    (function ensureCollapseChrome() {
        if (document.getElementById("riToggle")) return;
        const head = root.querySelector(".ri-head");
        if (!head) return;
        const first = head.firstElementChild;
        const wrap = document.createElement("div");
        wrap.className = "ri-head-main";
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "ri-toggle";
        btn.id = "riToggle";
        btn.setAttribute("aria-expanded", "true");
        btn.setAttribute("aria-controls", "riCollapse");
        btn.title = "Open / close insights";
        btn.innerHTML = '<i class="bi bi-chevron-down ri-toggle-icon" aria-hidden="true"></i>';
        wrap.appendChild(btn);
        if (first) wrap.appendChild(first);
        head.insertBefore(wrap, head.firstChild);

        const collapse = document.createElement("div");
        collapse.id = "riCollapse";
        collapse.className = "ri-collapse";
        const alertEl = document.getElementById("riAlert");
        const bodyEl = document.getElementById("riBody");
        if (alertEl) collapse.appendChild(alertEl);
        if (bodyEl) collapse.appendChild(bodyEl);
        root.appendChild(collapse);
    })();

    const toggle = document.getElementById("riToggle");
    function setOpen(open) {
        root.classList.toggle("ri-collapsed", !open);
        if (toggle) toggle.setAttribute("aria-expanded", open ? "true" : "false");
        if (open) ensureLoaded();
    }
    setOpen(false);
    if (toggle) {
        toggle.addEventListener("click", () => setOpen(root.classList.contains("ri-collapsed")));
    }
    const headMain = root.querySelector(".ri-head-main h3");
    if (headMain) {
        headMain.style.cursor = "pointer";
        headMain.addEventListener("click", () => setOpen(root.classList.contains("ri-collapsed")));
    }
})();
