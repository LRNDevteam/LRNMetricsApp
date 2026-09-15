/* ============================================================
   Notes & Insights front-end controller.
   Generic, report-agnostic. Reads context (lab, report, RUNID,
   week range) from #niRoot data-* attributes and drives the
   NotesController JSON API. No framework, no inline SQL.

   Active view = an INLINE-EDITABLE grid: Add Insight Row adds a
   blank editable row, existing rows are edited in place, and a
   single "Save Changes" at the bottom persists new + changed rows
   (each save is versioned + revision-logged by the stored procs).
   Masters: Risk (dbo.NotesRiskLevel), Responsible Party
   (dbo.NotesResponsibleParty).
   ============================================================ */
(function () {
    "use strict";

    const root = document.getElementById("niRoot");
    if (!root) return;

    function parseWeekRange(text) {
        const out = { start: "", end: "" };
        if (!text) return out;
        const parts = String(text).split(/\s*[-–—to]+\s*/i).filter(Boolean);
        const toIso = s => {
            s = s.trim();
            let m = s.match(/^(\d{1,2})[.\/](\d{1,2})[.\/](\d{4})$/);
            if (m) return `${m[3]}-${m[1].padStart(2, "0")}-${m[2].padStart(2, "0")}`;
            m = s.match(/^(\d{4})[-.\/](\d{1,2})[-.\/](\d{1,2})$/);
            if (m) return `${m[1]}-${m[2].padStart(2, "0")}-${m[3].padStart(2, "0")}`;
            const d = new Date(s);
            return isNaN(d) ? "" : d.toISOString().slice(0, 10);
        };
        if (parts.length >= 2) { out.start = toIso(parts[0]); out.end = toIso(parts[1]); }
        else if (parts.length === 1) { out.start = out.end = toIso(parts[0]); }
        return out;
    }

    const wk = parseWeekRange(root.dataset.weekText || "");
    const todayIso = new Date().toISOString().slice(0, 10);

    const ctx = {
        lab: root.dataset.lab || "",
        reportName: root.dataset.reportName || "Executive Summary",
        runId: root.dataset.runId || "",
        weekText: root.dataset.weekText || "",
        weekStart: root.dataset.weekStart || wk.start || todayIso,
        weekEnd: root.dataset.weekEnd || wk.end || wk.start || todayIso,
        token: (root.querySelector('input[name="__RequestVerificationToken"]') || {}).value || ""
    };

    // App base path (respects IIS virtual-directory / sub-application hosting).
    // "~/" renders as "/" at site root or "/AppAlias/" under a virtual dir.
    const apiBase = (root.dataset.base || "/").replace(/\/$/, "");

    let reportKeyId = 0;
    let lookups = { risks: [], statuses: [], responsibleParties: [] };
    const DEFAULT_LOOKUPS = {
        risks: [{ code: "Red", label: "High Risk" }, { code: "Yellow", label: "Medium / Watch" }, { code: "Green", label: "Low / Resolved" }],
        statuses: [{ code: "Open", label: "Open" }, { code: "WIP", label: "In Progress" }, { code: "Deferred", label: "Deferred" }, { code: "Closed", label: "Closed" }],
        responsibleParties: []
    };

    // active-view state
    let ridSeq = 1;
    const state = { rows: [], filters: {} };

    const el = {
        callout: root.querySelector(".ni-callout"),
        header: root.querySelector(".ni-header"),
        body: root.querySelector(".ni-body"),
        toolbar: root.querySelector(".ni-toolbar"),
        context: root.querySelector(".ni-context"),
        footer: root.querySelector("[data-ni-footer]")
    };

    // ---- helpers ----
    const esc = s => (s == null ? "" : String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])));
    const fmtDate = s => { if (!s) return ""; const d = new Date(s); return isNaN(d) ? "" : d.toLocaleDateString(); };
    const fmtDT = s => { if (!s) return ""; const d = new Date(s); return isNaN(d) ? "" : d.toLocaleString(); };
    const isoDate = s => { if (!s) return ""; const d = new Date(s); return isNaN(d) ? "" : d.toISOString().slice(0, 10); };
    const q = (obj) => Object.entries(obj).filter(([, v]) => v !== null && v !== undefined && v !== "").map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join("&");
    const stripHtml = s => { if (!s) return ""; const d = document.createElement("div"); d.innerHTML = s; return d.textContent || d.innerText || ""; };
    const debounce = (fn, ms) => { let t; return function () { clearTimeout(t); t = setTimeout(fn, ms); }; };

    function toast(msg) {
        let t = document.querySelector(".ni-toast");
        if (!t) { t = document.createElement("div"); t.className = "ni-toast"; document.body.appendChild(t); }
        t.textContent = msg; t.classList.add("show");
        setTimeout(() => t.classList.remove("show"), 2200);
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
    const getJson = (path) => api(path, { headers: { "Accept": "application/json" } });
    const postJson = (path, body) => api(path, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json", "RequestVerificationToken": ctx.token },
        body: body ? JSON.stringify(body) : null
    });

    function riskPill(code, label) { return `<span class="ni-pill risk-${esc(code)}">${esc(label || code)}</span>`; }
    function statusPill(code, label) { return `<span class="ni-pill status-${esc(code)}">${esc(label || code)}</span>`; }
    // Risk dropdown shows RiskCode; RiskLabel rides along as tooltip (watermark).
    function riskOptions(sel) { return lookups.risks.map(r => `<option value="${esc(r.code)}" title="${esc(r.label)}" ${r.code === sel ? "selected" : ""}>${esc(r.code)}</option>`).join(""); }
    function statusOptions(sel) { return lookups.statuses.map(s => `<option value="${esc(s.code)}" ${s.code === sel ? "selected" : ""}>${esc(s.label)}</option>`).join(""); }
    function partyOptions(sel) {
        const list = lookups.responsibleParties || [];
        let found = false;
        let opts = `<option value="">— Select —</option>` + list.map(p => { if (p === sel) found = true; return `<option value="${esc(p)}" ${p === sel ? "selected" : ""}>${esc(p)}</option>`; }).join("");
        if (sel && !found) opts = `<option value="${esc(sel)}" selected>${esc(sel)} (legacy)</option>` + opts;
        return opts;
    }
    function riskLabelFor(code) { const r = (lookups.risks || []).find(x => x.code === code); return r ? r.label : ""; }

    // ---- window: open/close/drag ----
    function openCallout() { el.callout.classList.add("ni-open"); showActive(); }
    function closeCallout() { el.callout.classList.remove("ni-open"); }

    (function enableDrag() {
        let sx, sy, ox, oy, dragging = false;
        el.header.addEventListener("mousedown", e => {
            if (e.target.closest(".ni-win-actions")) return;
            dragging = true;
            const r = el.callout.getBoundingClientRect();
            el.callout.style.transform = "none";
            el.callout.style.left = r.left + "px"; el.callout.style.top = r.top + "px";
            sx = e.clientX; sy = e.clientY; ox = r.left; oy = r.top;
            document.body.style.userSelect = "none";
        });
        window.addEventListener("mousemove", e => {
            if (!dragging) return;
            el.callout.style.left = (ox + e.clientX - sx) + "px";
            el.callout.style.top = Math.max(0, oy + e.clientY - sy) + "px";
        });
        window.addEventListener("mouseup", () => { dragging = false; document.body.style.userSelect = ""; });
    })();

    // ---- context strip ----
    function renderContext(archive) {
        el.context.innerHTML =
            `<div class="ni-ctx-item"><span>Report Name</span><br><b>${esc(ctx.reportName)}</b></div>` +
            `<div class="ni-ctx-item"><span>Week Range</span><br><b>${esc(ctx.weekText || "—")}</b></div>` +
            `<div class="ni-ctx-item"><span>Report ID / RUNID</span><br><b>${esc(ctx.runId || "—")}</b></div>` +
            `<div class="ni-ctx-item"><span>Archive Status</span><br><b>${archive ? "Archived (read-only)" : "Active"}</b></div>`;
    }

    /* =========================================================
       ACTIVE VIEW — inline-editable grid
       ========================================================= */
    async function showActive() {
        renderContext(false);
        el.body.classList.add("ni-body-active");
        el.toolbar.innerHTML =
            `<button class="btn btn-sm btn-primary" data-act="add">＋ Add Insight Row</button>` +
            `<button class="btn btn-sm btn-outline-secondary" data-act="import">⇧ Import Excel</button>` +
            `<button class="btn btn-sm btn-outline-secondary" data-act="template">▤ Template Library</button>` +
            `<button class="btn btn-sm btn-outline-secondary" data-act="archive">▥ Archived Notes</button>` +
            `<span class="ni-spacer"></span>` +
            `<span class="ni-drag-hint">Drag header to move · drag bottom-right corner to resize</span>`;
        el.toolbar.querySelector('[data-act="add"]').onclick = addRow;
        el.toolbar.querySelector('[data-act="import"]').onclick = () => toast("Import Excel: backend ready (usp_NotesImport_*). UI coming in a later iteration.");
        el.toolbar.querySelector('[data-act="template"]').onclick = () => toast("Template Library: backend ready (usp_NotesTemplate_*). UI coming in a later iteration.");
        el.toolbar.querySelector('[data-act="archive"]').onclick = showArchive;

        el.footer.innerHTML =
            `<span class="ni-foot-note">Shows latest 4-week Notes &amp; Insights plus older Open / WIP / Deferred carry-forward items. Closed notes older than 4 weeks move to Archived Notes.</span>` +
            `<span class="ni-spacer"></span>` +
            `<button class="btn btn-sm btn-outline-secondary" data-act="cancel">Cancel</button>` +
            `<button class="btn btn-sm btn-success" data-act="save">💾 Save Changes</button>`;
        el.footer.querySelector('[data-act="cancel"]').onclick = onCancel;
        el.footer.querySelector('[data-act="save"]').onclick = saveAll;

        el.body.innerHTML = `<div class="ni-loading">Loading active notes…</div>`;
        await loadActive();
    }

    async function loadActive() {
        try {
            const data = await getJson(`${apiBase}/Notes/Active?${q({ lab: ctx.lab, report: ctx.reportName })}`);
            reportKeyId = data.reportKeyId;
            state.rows = (data.rows || []).map(mapServerRow);
            state.filters = {};
            renderActiveBody();
        } catch (e) { el.body.innerHTML = `<div class="ni-empty">⚠ ${esc(e.message)}</div>`; }
    }

    function mapServerRow(n) {
        return {
            _rid: ridSeq++, _new: false, _dirty: false,
            noteId: n.noteId, entryNo: n.entryNo,
            weekRangeText: n.weekRangeText || ctx.weekText,
            weekRangeStart: isoDate(n.weekRangeStart) || ctx.weekStart,
            weekRangeEnd: isoDate(n.weekRangeEnd) || ctx.weekEnd,
            riskCode: n.riskCode || "Yellow", riskLabel: n.riskLabel,
            responsibleParty: n.responsibleParty || "",
            insights: n.insights || "",
            noOfSamples: n.noOfSamples ?? "",
            actionSolution: n.actionSolution || "",
            feedbackResponse: n.feedbackResponse || "",
            responsibility: n.responsibility || "",
            discussionDate: isoDate(n.discussionDate),
            eta: isoDate(n.eta), closedDate: isoDate(n.closedDate),
            statusCode: n.statusCode || "Open", statusLabel: n.statusLabel,
            archiveStatus: n.archiveStatus || "Active",
            isOverdueETA: !!n.isOverdueETA
        };
    }

    function addRow() {
        state.rows.unshift({
            _rid: ridSeq++, _new: true, _dirty: true,
            noteId: null, entryNo: null,
            weekRangeText: ctx.weekText, weekRangeStart: ctx.weekStart, weekRangeEnd: ctx.weekEnd,
            riskCode: "Yellow", responsibleParty: "", insights: "", noOfSamples: "",
            actionSolution: "", feedbackResponse: "", responsibility: "",
            discussionDate: "", eta: "", closedDate: "", statusCode: "Open", archiveStatus: "Active", isOverdueETA: false
        });
        state.filters = {}; // show everything so the new row is visible
        renderActiveBody();
    }

    function summary() {
        const rows = state.rows;
        return {
            active: rows.length,
            carry: rows.filter(r => r.archiveStatus === "Carry Forward").length,
            redOpen: rows.filter(r => r.riskCode === "Red" && r.statusCode !== "Closed").length,
            overdue: rows.filter(r => r.isOverdueETA && r.statusCode !== "Closed").length
        };
    }

    function distinctWeeks() {
        return [...new Set(state.rows.map(r => r.weekRangeText).filter(Boolean))];
    }

    function applyFilters() {
        const f = state.filters || {};
        const inRange = (d, from, to) => {
            if (!from && !to) return true;
            if (!d) return false;
            const x = new Date(d);
            if (from && x < new Date(from)) return false;
            if (to && x > new Date(to)) return false;
            return true;
        };
        const term = (f.search || "").toLowerCase();
        return state.rows.filter(r => {
            if (f.week && r.weekRangeText !== f.week) return false;
            if (f.status && r.statusCode !== f.status) return false;
            if (f.risk && r.riskCode !== f.risk) return false;
            if (f.responsibility && r.responsibility !== f.responsibility) return false;
            if (!inRange(r.discussionDate, f.discFrom, f.discTo)) return false;
            if (!inRange(r.eta, f.etaFrom, f.etaTo)) return false;
            if (term) {
                const hay = [r.weekRangeText, r.responsibleParty, stripHtml(r.insights), stripHtml(r.actionSolution),
                    stripHtml(r.feedbackResponse), r.statusCode, r.riskCode, r.responsibility].join(" ").toLowerCase();
                if (!hay.includes(term)) return false;
            }
            return true;
        });
    }

    function renderActiveBody() {
        const s = summary();
        const weeks = distinctWeeks();
        const f = state.filters || {};
        const cards = `
        <div class="ni-cards">
          <div class="ni-card"><div class="ni-card-val">${s.active}</div><div class="ni-card-lbl">Active Insights</div><div class="ni-card-sub">4-week + carry-forward</div></div>
          <div class="ni-card"><div class="ni-card-val">${s.carry}</div><div class="ni-card-lbl">Open Carry Forward</div><div class="ni-card-sub">Older unresolved items</div></div>
          <div class="ni-card"><div class="ni-card-val">${s.redOpen}</div><div class="ni-card-lbl">Red Risk Open</div><div class="ni-card-sub">High-risk follow-up</div></div>
          <div class="ni-card"><div class="ni-card-val">${s.overdue}</div><div class="ni-card-lbl">Overdue ETA</div><div class="ni-card-sub">ETA past due, not closed</div></div>
        </div>`;

        const filters = `
        <div class="ni-filters">
          <div class="ni-filters-head"><b>Filters</b><span class="ni-filters-note">Search and filters apply to the current report notes shown below.</span></div>
          <div class="ni-filter-grid">
            <div class="ni-ff ni-ff-wide"><label>Search Active Insights</label><input type="search" data-flt="search" value="${esc(f.search || "")}" placeholder="Search week, owner, insight, action, feedback, status, risk…" /></div>
            <div class="ni-ff"><label>Week Range</label><select data-flt="week"><option value="">All active weeks</option>${weeks.map(w => `<option value="${esc(w)}" ${f.week === w ? "selected" : ""}>${esc(w)}</option>`).join("")}</select></div>
            <div class="ni-ff"><label>Discussion Date</label><div class="ni-ff-range"><input type="date" data-flt="discFrom" value="${esc(f.discFrom || "")}" /><input type="date" data-flt="discTo" value="${esc(f.discTo || "")}" /></div></div>
            <div class="ni-ff"><label>ETA Date</label><div class="ni-ff-range"><input type="date" data-flt="etaFrom" value="${esc(f.etaFrom || "")}" /><input type="date" data-flt="etaTo" value="${esc(f.etaTo || "")}" /></div></div>
            <div class="ni-ff"><label>Responsibility</label><select data-flt="responsibility"><option value="">All</option>${(lookups.responsibleParties || []).map(p => `<option value="${esc(p)}" ${f.responsibility === p ? "selected" : ""}>${esc(p)}</option>`).join("")}</select></div>
            <div class="ni-ff"><label>Status</label><select data-flt="status"><option value="">All</option>${statusOptions(f.status || "")}</select></div>
            <div class="ni-ff"><label>Risk</label><select data-flt="risk"><option value="">All</option>${riskOptions(f.risk || "")}</select></div>
            <div class="ni-ff"><label>&nbsp;</label><button class="btn btn-sm btn-outline-secondary" data-act="clear">Clear Filters</button></div>
          </div>
        </div>`;

        el.body.innerHTML = cards + filters + `<div class="ni-gridzone">${renderGridZone(applyFilters())}</div>`;

        // filter listeners
        el.body.querySelectorAll("[data-flt]").forEach(inp => {
            const ev = inp.type === "search" || inp.type === "text" ? "input" : "change";
            inp.addEventListener(ev, debounce(() => {
                el.body.querySelectorAll("[data-flt]").forEach(x => state.filters[x.dataset.flt] = x.value || "");
                el.body.querySelector(".ni-gridzone").innerHTML = renderGridZone(applyFilters());
                bindGrid();
            }, 250));
        });
        const clearBtn = el.body.querySelector('[data-act="clear"]');
        if (clearBtn) clearBtn.onclick = () => { state.filters = {}; renderActiveBody(); };
        bindGrid();
    }

    function renderGridZone(filtered) {
        return `<div class="ni-gridbar">` +
               `<span class="ni-count">Showing ${filtered.length} of ${state.rows.length} active notes</span>` +
               `<span class="ni-gridbar-note">Active Notes includes latest 4 weeks plus older Open / WIP / Deferred carry-forward items.</span>` +
               `</div><div class="ni-grid-wrap">${renderGrid(filtered)}</div>`;
    }

    function renderGrid(rows) {
        if (!rows.length) return `<div class="ni-empty">No active notes match. Use “＋ Add Insight Row” to create one.</div>`;
        const head = `<tr>
            <th>#</th><th>Week Range</th><th>Risk</th><th>Responsible Party</th><th>Insights</th><th>#Smp</th>
            <th>Action / Solution</th><th>Feedback / Response</th><th>Responsibility</th>
            <th>Discussion</th><th>ETA</th><th>Closed</th><th>Status</th><th>Action</th></tr>`;
        const body = rows.map(r => {
            const rid = r._rid;
            const overdue = r.isOverdueETA && r.statusCode !== "Closed" ? `<span class="ni-pill ni-overdue">Overdue</span>` : "";
            const winPill = r._new ? `<span class="ni-pill ni-current">New Row</span>`
                : r.archiveStatus === "Carry Forward" ? `<span class="ni-pill ni-carry">Carry Forward</span>`
                : `<span class="ni-pill ni-current">Current Window</span>`;
            return `<tr data-rid="${rid}" class="ni-row-main">
                <td class="ni-num">${r._new ? "new" : esc(r.entryNo ?? "")}</td>
                <td class="ni-week">${esc(r.weekRangeText || "")}<div class="ni-week-pills">${winPill}${overdue}</div></td>
                <td class="ni-td-risk"><select data-rid="${rid}" data-field="riskCode" class="ni-risk">${riskOptions(r.riskCode)}</select>
                    <div class="ni-risk-pill">${riskPill(r.riskCode, r.riskCode)}</div></td>
                <td class="ni-td-party"><select data-rid="${rid}" data-field="responsibleParty">${partyOptions(r.responsibleParty)}</select></td>
                <td class="ni-td-insights"><textarea data-rid="${rid}" data-field="insights" class="ni-insights-box" wrap="off" placeholder="Enter insight…">${esc(r.insights)}</textarea></td>
                <td class="ni-td-smp"><input data-rid="${rid}" data-field="noOfSamples" type="text" size="6" class="ni-smp" value="${esc(r.noOfSamples)}" /></td>
                <td class="ni-td-text"><textarea data-rid="${rid}" data-field="actionSolution" placeholder="Action…">${esc(r.actionSolution)}</textarea></td>
                <td class="ni-td-text"><textarea data-rid="${rid}" data-field="feedbackResponse" placeholder="Feedback…">${esc(r.feedbackResponse)}</textarea></td>
                <td class="ni-td-party"><select data-rid="${rid}" data-field="responsibility">${partyOptions(r.responsibility)}</select></td>
                <td class="ni-td-date"><input data-rid="${rid}" data-field="discussionDate" type="date" value="${esc(r.discussionDate)}" /></td>
                <td class="ni-td-date"><input data-rid="${rid}" data-field="eta" type="date" value="${esc(r.eta)}" /></td>
                <td class="ni-td-date"><input data-rid="${rid}" data-field="closedDate" type="date" value="${esc(r.closedDate)}" /></td>
                <td class="ni-td-status"><select data-rid="${rid}" data-field="statusCode">${statusOptions(r.statusCode)}</select></td>
                <td class="ni-actions">
                    ${r._new ? "" : `<button title="Revision History" data-rowact="rev" data-rid="${rid}">🕑</button>`}
                    <button title="Delete" data-rowact="del" data-rid="${rid}" class="ni-act-del">🗑</button>
                </td></tr>`;
        }).join("");
        return `<table class="ni-table ni-grid-edit"><thead>${head}</thead><tbody>${body}</tbody></table>`;
    }

    function rowByRid(rid) { return state.rows.find(r => String(r._rid) === String(rid)); }

    function bindGrid() {
        const grid = el.body.querySelector(".ni-grid-edit");
        if (!grid) return;
        const onEdit = e => {
            const t = e.target;
            if (!t.dataset || !t.dataset.field) return;
            const row = rowByRid(t.dataset.rid);
            if (!row) return;
            row[t.dataset.field] = t.value;
            if (!row._new) row._dirty = true;
            if (t.dataset.field === "riskCode") {
                const cell = t.closest("td");
                const pill = cell && cell.querySelector(".ni-risk-pill");
                if (pill) pill.innerHTML = riskPill(t.value, t.value);
            }
        };
        grid.addEventListener("input", onEdit);
        grid.addEventListener("change", onEdit);
        grid.querySelectorAll("[data-rowact]").forEach(b => {
            b.onclick = () => {
                const row = rowByRid(b.dataset.rid);
                if (!row) return;
                if (b.dataset.rowact === "rev") showRevisions(row.noteId, showActive);
                else deleteRow(row);
            };
        });
    }

    async function deleteRow(row) {
        if (row._new) { state.rows = state.rows.filter(r => r._rid !== row._rid); renderActiveBody(); return; }
        if (!confirm("Delete this active note? This cannot be undone.")) return;
        try { await postJson(`${apiBase}/Notes/Delete?${q({ lab: ctx.lab, id: row.noteId })}`); toast("Note deleted."); await loadActive(); }
        catch (e) { alert(e.message); }
    }

    function buildPayload(r) {
        return {
            noteId: r._new ? null : r.noteId,
            reportName: ctx.reportName, reportRunId: ctx.runId || null,
            weekRangeText: r.weekRangeText || ctx.weekText || null,
            weekRangeStart: r.weekRangeStart || ctx.weekStart || null,
            weekRangeEnd: r.weekRangeEnd || ctx.weekEnd || null,
            riskCode: r.riskCode || "Yellow",
            responsibleParty: r.responsibleParty || null,
            insights: r.insights || null,
            noOfSamples: r.noOfSamples !== "" && r.noOfSamples != null ? parseInt(r.noOfSamples, 10) : null,
            actionSolution: r.actionSolution || null,
            feedbackResponse: r.feedbackResponse || null,
            responsibility: r.responsibility || null,
            discussionDate: r.discussionDate || null,
            eta: r.eta || null, closedDate: r.closedDate || null,
            statusCode: r.statusCode || "Open"
        };
    }

    function hasContent(r) {
        return (r.insights || r.responsibleParty || r.actionSolution || r.feedbackResponse || r.responsibility || r.noOfSamples || r.eta || r.discussionDate);
    }

    async function saveAll() {
        const inserts = state.rows.filter(r => r._new && hasContent(r));
        const updates = state.rows.filter(r => !r._new && r._dirty && r.noteId);
        if (!inserts.length && !updates.length) { toast("No changes to save."); return; }
        const btn = el.footer.querySelector('[data-act="save"]');
        if (btn) { btn.disabled = true; btn.textContent = "Saving…"; }
        try {
            for (const r of inserts) await postJson(`${apiBase}/Notes/Save?${q({ lab: ctx.lab, report: ctx.reportName })}`, buildPayload(r));
            for (const r of updates) await postJson(`${apiBase}/Notes/Save?${q({ lab: ctx.lab, report: ctx.reportName })}`, buildPayload(r));
            toast(`Saved ${inserts.length + updates.length} change(s) — new versions recorded.`);
            await loadActive();
        } catch (e) { alert(e.message); }
        finally { if (btn) { btn.disabled = false; btn.innerHTML = "💾 Save Changes"; } }
    }

    function onCancel() {
        const dirty = state.rows.some(r => r._new || r._dirty);
        if (dirty && !confirm("Discard unsaved changes?")) return;
        closeCallout();
    }

    /* =========================================================
       ARCHIVE (read-only) + REVISION HISTORY + read-only detail
       ========================================================= */
    async function showArchive() {
        renderContext(true);
        el.body.classList.remove("ni-body-active");
        el.footer.innerHTML = "";
        el.toolbar.innerHTML =
            `<button class="btn btn-sm btn-link" data-act="back">‹ Back to Active</button>` +
            `<input type="search" id="niSearchA" placeholder="Search archived…" />` +
            `<select id="niFRiskA"><option value="">All Risk</option>${riskOptions("")}</select>`;
        el.toolbar.querySelector('[data-act="back"]').onclick = showActive;
        el.body.innerHTML = `<div class="ni-loading">Loading archive…</div>`;
        const reload = debounce(loadArchive, 300);
        el.toolbar.querySelector("#niSearchA").addEventListener("input", reload);
        el.toolbar.querySelector("#niFRiskA").onchange = loadArchive;
        await loadArchive();
    }

    async function loadArchive() {
        try {
            const sv = (el.toolbar.querySelector("#niSearchA") || {}).value || "";
            const rk = (el.toolbar.querySelector("#niFRiskA") || {}).value || "";
            const data = await getJson(`${apiBase}/Notes/Archived?${q({ lab: ctx.lab, report: ctx.reportName, risk: rk, search: sv })}`);
            const s = data.summary || {};
            const cards = `<div class="ni-cards">
                <div class="ni-card"><div class="ni-card-val">${s.totalArchived || 0}</div><div class="ni-card-lbl">Total Archived</div></div>
                <div class="ni-card"><div class="ni-card-val">${s.redRiskArchived || 0}</div><div class="ni-card-lbl">Red Risk Archived</div></div>
                <div class="ni-card"><div class="ni-card-val">${s.closedThisMonth || 0}</div><div class="ni-card-lbl">Closed This Month</div></div>
                <div class="ni-card"><div class="ni-card-val" style="font-size:.9rem">${fmtDate(s.lastArchivedDate) || "—"}</div><div class="ni-card-lbl">Last Archived</div></div>
            </div>`;
            const rows = data.rows || [];
            const table = rows.length ? `<table class="ni-table"><thead>
                <tr><th>#</th><th>Week Range</th><th>Risk</th><th>Responsible</th><th>Insights</th><th>Status</th><th>Closed</th><th>Archived</th><th></th></tr></thead>
                <tbody>${rows.map(n => `<tr>
                    <td>${esc(n.entryNo ?? "")}</td><td>${esc(n.weekRangeText || "")}</td>
                    <td>${riskPill(n.riskCode, n.riskCode)}</td><td>${esc(n.responsibleParty || "")}</td>
                    <td><div class="ni-truncate">${esc(stripHtml(n.insights))}</div></td>
                    <td>${statusPill(n.statusCode, n.statusLabel)}</td>
                    <td>${esc(fmtDate(n.closedDate))}</td><td>${esc(fmtDate(n.archivedDate))}</td>
                    <td class="ni-actions"><button title="View" data-act="view" data-id="${n.noteId}">👁</button><button title="Revision History" data-act="rev" data-id="${n.noteId}">🕑</button></td>
                </tr>`).join("")}</tbody></table>`
                : `<div class="ni-empty">No archived notes for this report.</div>`;
            el.body.innerHTML = cards + table;
            el.body.querySelectorAll(".ni-actions button").forEach(b => {
                b.onclick = () => { const id = +b.dataset.id; if (b.dataset.act === "view") showReadOnlyDetail(id); else showRevisions(id, showArchive); };
            });
        } catch (e) { el.body.innerHTML = `<div class="ni-empty">⚠ ${esc(e.message)}</div>`; }
    }

    async function showReadOnlyDetail(id) {
        el.body.classList.remove("ni-body-active");
        el.footer.innerHTML = "";
        el.toolbar.innerHTML = `<button class="btn btn-sm btn-link" data-act="back">‹ Back to Archived Notes</button>`;
        el.toolbar.querySelector('[data-act="back"]').onclick = showArchive;
        el.body.innerHTML = `<div class="ni-loading">Loading…</div>`;
        let n;
        try { n = await getJson(`${apiBase}/Notes/Detail?${q({ lab: ctx.lab, id })}`); }
        catch (e) { el.body.innerHTML = `<div class="ni-empty">⚠ ${esc(e.message)}</div>`; return; }
        const ro = v => `<div class="ni-ro">${esc(v || "—")}</div>`;
        el.body.innerHTML = `
        <div class="ni-detail">
          <div class="ni-detail-head"><span class="ni-detail-title">Archived Note Detail</span> ${riskPill(n.riskCode, n.riskCode)} ${statusPill(n.statusCode, n.statusLabel)}</div>
          <div class="ni-banner">This note is archived and read-only. Editing, deleting and reopening are disabled.</div>
          <div class="ni-section"><h6>Context</h6><div class="ni-grid">
            <div class="ni-field"><label>Report Name</label>${ro(n.reportName)}</div>
            <div class="ni-field"><label>Week Range</label>${ro(n.weekRangeText)}</div>
            <div class="ni-field"><label>Report ID / RUNID</label>${ro(n.reportRunId)}</div>
            <div class="ni-field"><label>Note / Entry ID</label>${ro(n.noteId)}</div></div></div>
          <div class="ni-section"><h6>Insight</h6><div class="ni-grid">
            <div class="ni-field"><label>Risk</label><div class="ni-ro">${esc(n.riskCode)}</div><small class="ni-watermark">${esc(n.riskLabel)}</small></div>
            <div class="ni-field"><label>Responsible Party</label>${ro(n.responsibleParty)}</div>
            <div class="ni-field"><label># of Samples</label>${ro(n.noOfSamples)}</div>
            <div class="ni-field"><label>Status</label>${ro(n.statusLabel || n.statusCode)}</div>
            <div class="ni-field full"><label>Insights</label><div class="ni-ro">${esc(stripHtml(n.insights)) || "—"}</div></div></div></div>
          <div class="ni-section"><h6>Action &amp; Response</h6><div class="ni-grid">
            <div class="ni-field full"><label>Action / Solution / Suggestions</label><div class="ni-ro">${esc(stripHtml(n.actionSolution)) || "—"}</div></div>
            <div class="ni-field full"><label>Feedback / Response</label><div class="ni-ro">${esc(stripHtml(n.feedbackResponse)) || "—"}</div></div>
            <div class="ni-field"><label>Responsibility</label>${ro(n.responsibility)}</div></div></div>
          <div class="ni-section"><h6>Timeline</h6><div class="ni-grid">
            <div class="ni-field"><label>Discussion Date</label>${ro(fmtDate(n.discussionDate))}</div>
            <div class="ni-field"><label>ETA</label>${ro(fmtDate(n.eta))}</div>
            <div class="ni-field"><label>Closed Date</label>${ro(fmtDate(n.closedDate))}</div>
            <div class="ni-field"><label>Archived Date</label>${ro(fmtDate(n.archivedDate))}</div></div></div>
          <div class="ni-section"><h6>Audit Metadata</h6><div class="ni-grid">
            <div class="ni-field"><label>Created By</label>${ro(n.createdBy)}</div>
            <div class="ni-field"><label>Created Date/Time</label>${ro(fmtDT(n.createdDateTime))}</div>
            <div class="ni-field"><label>Last Edited By</label>${ro(n.lastEditedBy)}</div>
            <div class="ni-field"><label>Last Edited Date/Time</label>${ro(fmtDT(n.lastEditedDateTime))}</div>
            <div class="ni-field"><label>Version</label>${ro("v" + (n.versionNumber || 1))}</div></div></div>
          <div class="ni-section"><button class="btn btn-sm btn-outline-secondary" data-act="rev">🕑 View Revision History</button></div>
        </div>`;
        el.body.querySelector('[data-act="rev"]').onclick = () => showRevisions(id, () => showReadOnlyDetail(id));
    }

    async function showRevisions(id, backFn) {
        el.body.classList.remove("ni-body-active");
        el.footer.innerHTML = "";
        el.toolbar.innerHTML = `<button class="btn btn-sm btn-link" data-act="back">‹ Back</button>`;
        el.toolbar.querySelector('[data-act="back"]').onclick = backFn || showActive;
        el.body.innerHTML = `<div class="ni-loading">Loading revision history…</div>`;
        try {
            const rows = await getJson(`${apiBase}/Notes/Revisions?${q({ lab: ctx.lab, id })}`);
            if (!rows.length) { el.body.innerHTML = `<div class="ni-empty">No revision events recorded.</div>`; return; }
            el.body.innerHTML = `<div class="ni-timeline">` + rows.map(r => `
                <div class="ni-rev">
                    <div class="ni-rev-type">${esc(r.eventType)} <span class="ni-pill status-Open">v${esc(r.versionNumber)}</span></div>
                    <div class="ni-rev-meta">${esc(fmtDT(r.eventDateTime))} · ${esc(r.eventUser || "—")}${r.sourceAction ? " · " + esc(r.sourceAction) : ""}</div>
                    <div class="ni-rev-sum">${esc(r.revisionSummary || "")}</div>
                </div>`).join("") + `</div>`;
        } catch (e) { el.body.innerHTML = `<div class="ni-empty">⚠ ${esc(e.message)}</div>`; }
    }

    // ---- wire up open button + window chrome ----
    document.querySelectorAll("[data-ni-open]").forEach(b => b.addEventListener("click", async (e) => {
        e.preventDefault();
        if (!lookups.risks.length) {
            try {
                const loaded = await getJson(`${apiBase}/Notes/Lookups?${q({ lab: ctx.lab })}`);
                lookups = { risks: loaded.risks || DEFAULT_LOOKUPS.risks, statuses: loaded.statuses || DEFAULT_LOOKUPS.statuses, responsibleParties: loaded.responsibleParties || [] };
            } catch { lookups = DEFAULT_LOOKUPS; }
        }
        openCallout();
    }));
    root.querySelector("[data-ni-close]").addEventListener("click", closeCallout);
    const min = root.querySelector("[data-ni-min]");
    if (min) min.addEventListener("click", () => el.callout.classList.toggle("ni-collapsed"));

    // Feature gate: enable Notes & Insights only when the Insights tables exist
    // in this lab's database. The open button stays visible by default (no
    // flicker for enabled labs) and is hidden if the check reports unavailable.
    (async function gateFeature() {
        const hide = () => document.querySelectorAll("[data-ni-open]").forEach(b => { b.style.display = "none"; });
        try {
            const r = await getJson(`${apiBase}/Notes/Available?${q({ lab: ctx.lab })}`);
            // Hide ONLY when the database explicitly reports the tables are missing.
            if (r && r.available === false) hide();
            // fail-open: on a malformed/empty response, keep the button visible.
        } catch { /* fail-open: keep the button visible if the availability check itself fails */ }
    })();
})();
