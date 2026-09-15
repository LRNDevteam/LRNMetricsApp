(function () {
    "use strict";
    const root = document.getElementById("itmRoot");
    if (!root) return;

    const ctx = {
        lab: root.dataset.lab || "",
        reportName: root.dataset.reportName || "Production Report",
        token: (root.querySelector('input[name="__RequestVerificationToken"]') || {}).value || ""
    };
    const apiBase = (root.dataset.base || "/").replace(/\/$/, "");
    const q = obj => Object.entries(obj).filter(([, v]) => v != null && v !== "").map(([k, v]) => encodeURIComponent(k) + "=" + encodeURIComponent(v)).join("&");
    const esc = s => (s == null ? "" : String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])));

    const el = {
        alert: document.getElementById("itmAlert"),
        list: document.getElementById("itmTplList"),
        editor: document.getElementById("itmEditor"),
        editorTitle: document.getElementById("itmEditorTitle"),
        addCol: document.getElementById("itmAddCol"),
        seed: document.getElementById("itmSeedBtn"),
        newTpl: document.getElementById("itmNewTpl")
    };

    let templates = [];
    let selected = null;

    const SEED_COLUMNS = seedColumnsFor(ctx.reportName);

    function seedColumnsFor(reportName) {
        const r = (reportName || "").toLowerCase();
        const claims = r.includes("collection") ? "# of Cases" : "# of Claims";
        const charge = r.includes("collection") ? "Total Bill"
            : r.includes("lis") ? "Expected Reimbursement ($)"
            : "Total Charge";
        const data = r.includes("collection") ? "Case Link"
            : r.includes("lis") ? "Data Link"
            : "Data";
        const action = r.includes("collection") ? "Action / Solution / Suggestion" : "Action / Solution / Suggestions";
        const owner = r.includes("collection") ? "Response By" : "Responsibility";
        return [
            { columnName: "Risk", columnType: "Dropdown", isRequired: true, sortOrder: 1, fieldKey: "Risk", dropdownValues: "High|Medium|Low" },
            { columnName: "Responsible Party", columnType: "Text", sortOrder: 2, fieldKey: "ResponsibleParty" },
            { columnName: "Insights", columnType: "Text", isRequired: true, sortOrder: 3, fieldKey: "Insights" },
            { columnName: claims, columnType: "Text", sortOrder: 4, fieldKey: "NoOfClaims" },
            { columnName: charge, columnType: "Text", sortOrder: 5, fieldKey: "TotalCharge" },
            { columnName: data, columnType: "Text", sortOrder: 6, fieldKey: "DataLink" },
            { columnName: action, columnType: "Text", sortOrder: 7, fieldKey: "ActionSolution" },
            { columnName: "Feedback / Response", columnType: "Text", sortOrder: 8, fieldKey: "FeedbackResponse" },
            { columnName: owner, columnType: "Text", sortOrder: 9, fieldKey: "Responsibility" },
            { columnName: "Discussion Date", columnType: "Date", sortOrder: 10, fieldKey: "DiscussionDate" },
            { columnName: "ETA", columnType: "Date", sortOrder: 11, fieldKey: "ETA" },
            { columnName: "Closed Date", columnType: "Date", sortOrder: 12, fieldKey: "ClosedDate" },
            { columnName: "Status", columnType: "Dropdown", isRequired: true, sortOrder: 13, fieldKey: "Status", dropdownValues: "Yet to Discuss|Open|In Progress|Deferred|Closed" }
        ];
    }

    function showAlert(msg, kind) {
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

    function renderList() {
        if (!templates.length) {
            el.list.innerHTML = `<div class="itm-empty">No template yet. Create one or seed Key Insights &amp; Highlights.</div>`;
            return;
        }
        el.list.innerHTML = templates.map(t =>
            `<button type="button" class="itm-tpl ${selected && selected.templateId === t.templateId ? "active" : ""}" data-id="${t.templateId}">
                <b>${esc(t.templateName)}</b>
                <small>${(t.columns || []).length} column(s)</small>
            </button>`
        ).join("");
        el.list.querySelectorAll("[data-id]").forEach(btn => {
            btn.onclick = () => {
                selected = templates.find(t => String(t.templateId) === btn.getAttribute("data-id"));
                renderList();
                renderEditor();
            };
        });
    }

    function renderEditor() {
        if (!selected) {
            el.editorTitle.textContent = "Columns";
            el.addCol.hidden = true;
            el.seed.hidden = false;
            el.editor.innerHTML = `<div class="itm-empty">Select a template or create one. Use Seed to load the Key Insights &amp; Highlights fields from the mockup.</div>`;
            return;
        }
        el.editorTitle.textContent = selected.templateName;
        el.addCol.hidden = false;
        el.seed.hidden = (selected.columns || []).length > 0;
        const cols = selected.columns || [];
        if (!cols.length) {
            el.editor.innerHTML = `<div class="itm-empty">No columns yet. Seed the mockup fields or add your own.</div>`;
            return;
        }
        el.editor.innerHTML = `<table class="table table-sm itm-col-table"><thead><tr>
            <th>Name</th><th>Type</th><th>Field key</th><th>Required</th><th>Order</th><th>Dropdown values</th><th></th>
        </tr></thead><tbody>${cols.map(c => `<tr>
            <td><input class="form-control form-control-sm" data-f="columnName" data-id="${c.columnId}" value="${esc(c.columnName)}" /></td>
            <td><select class="form-select form-select-sm" data-f="columnType" data-id="${c.columnId}">
                ${["Text", "Date", "Dropdown"].map(t => `<option ${t === c.columnType ? "selected" : ""}>${t}</option>`).join("")}
            </select></td>
            <td><input class="form-control form-control-sm" data-f="fieldKey" data-id="${c.columnId}" value="${esc(c.fieldKey || "")}" /></td>
            <td class="text-center"><input type="checkbox" data-f="isRequired" data-id="${c.columnId}" ${c.isRequired ? "checked" : ""} /></td>
            <td><input type="number" class="form-control form-control-sm" data-f="sortOrder" data-id="${c.columnId}" value="${esc(c.sortOrder)}" style="width:4.5rem" /></td>
            <td><input class="form-control form-control-sm" data-f="dropdownValues" data-id="${c.columnId}" value="${esc((c.dropdownValues || []).join("|"))}" placeholder="A|B|C" ${c.columnType === "Dropdown" ? "" : "disabled"} /></td>
            <td>
                <button type="button" class="btn btn-sm btn-outline-primary" data-save="${c.columnId}">Save</button>
                <button type="button" class="btn btn-sm btn-outline-danger" data-del="${c.columnId}">Remove</button>
            </td>
        </tr>`).join("")}</tbody></table>`;

        el.editor.querySelectorAll("[data-f=columnType]").forEach(sel => {
            sel.onchange = () => {
                const row = sel.closest("tr");
                const dv = row.querySelector("[data-f=dropdownValues]");
                if (dv) dv.disabled = sel.value !== "Dropdown";
            };
        });
        el.editor.querySelectorAll("[data-save]").forEach(btn => btn.onclick = () => saveColumn(Number(btn.getAttribute("data-save"))));
        el.editor.querySelectorAll("[data-del]").forEach(btn => btn.onclick = () => deleteColumn(Number(btn.getAttribute("data-del"))));
    }

    function readColumnRow(id) {
        const g = f => el.editor.querySelector(`[data-f="${f}"][data-id="${id}"]`);
        return {
            columnId: id,
            templateId: selected.templateId,
            columnName: (g("columnName") || {}).value || "",
            columnType: (g("columnType") || {}).value || "Text",
            fieldKey: (g("fieldKey") || {}).value || null,
            isRequired: !!(g("isRequired") && g("isRequired").checked),
            sortOrder: parseInt((g("sortOrder") || {}).value || "0", 10),
            dropdownValues: (g("dropdownValues") || {}).value || null
        };
    }

    function dialog(modalEl) {
        if (!modalEl) return null;
        if (window.bootstrap && bootstrap.Modal) {
            return bootstrap.Modal.getOrCreateInstance(modalEl);
        }
        return null;
    }

    function askName(opts) {
        const modalEl = document.getElementById("itmPromptModal");
        const title = document.getElementById("itmPromptTitle");
        const label = document.getElementById("itmPromptLabel");
        const hint = document.getElementById("itmPromptHint");
        const input = document.getElementById("itmPromptInput");
        const ok = document.getElementById("itmPromptOk");
        if (!modalEl || !input || !ok) return Promise.resolve(null);

        title.textContent = opts.title || "Name";
        label.textContent = opts.label || "Name";
        hint.textContent = opts.hint || "";
        hint.hidden = !opts.hint;
        ok.textContent = opts.okText || "Save";
        input.value = opts.value || "";

        const modal = dialog(modalEl);
        return new Promise(resolve => {
            let done = false;
            const finish = value => {
                if (done) return;
                done = true;
                modalEl.removeEventListener("hidden.bs.modal", onHidden);
                ok.removeEventListener("click", onOk);
                input.removeEventListener("keydown", onKey);
                resolve(value);
            };
            const onOk = () => {
                const v = (input.value || "").trim();
                if (!v) { input.focus(); input.classList.add("is-invalid"); return; }
                input.classList.remove("is-invalid");
                finish(v);
                modal && modal.hide();
            };
            const onHidden = () => finish(null);
            const onKey = e => {
                if (e.key === "Enter") { e.preventDefault(); onOk(); }
            };
            input.classList.remove("is-invalid");
            ok.addEventListener("click", onOk);
            input.addEventListener("keydown", onKey);
            modalEl.addEventListener("hidden.bs.modal", onHidden, { once: true });
            modal && modal.show();
            modalEl.addEventListener("shown.bs.modal", () => { input.focus(); input.select(); }, { once: true });
        });
    }

    function askConfirm(opts) {
        const modalEl = document.getElementById("itmConfirmModal");
        const title = document.getElementById("itmConfirmTitle");
        const message = document.getElementById("itmConfirmMessage");
        const ok = document.getElementById("itmConfirmOk");
        if (!modalEl || !ok) return Promise.resolve(false);

        title.textContent = opts.title || "Confirm";
        message.textContent = opts.message || "Are you sure?";
        ok.textContent = opts.okText || "OK";
        ok.className = "btn " + (opts.danger ? "btn-danger" : "btn-primary");

        const modal = dialog(modalEl);
        return new Promise(resolve => {
            let done = false;
            const finish = value => {
                if (done) return;
                done = true;
                modalEl.removeEventListener("hidden.bs.modal", onHidden);
                ok.removeEventListener("click", onOk);
                resolve(value);
            };
            const onOk = () => {
                finish(true);
                modal && modal.hide();
            };
            const onHidden = () => finish(false);
            ok.addEventListener("click", onOk);
            modalEl.addEventListener("hidden.bs.modal", onHidden, { once: true });
            modal && modal.show();
        });
    }

    async function saveColumn(id) {
        const req = readColumnRow(id);
        if (!req.columnName.trim()) { showAlert("Column name is required.", "error"); return; }
        await postJson(`${apiBase}/Notes/TemplateColumnSave?${q({ lab: ctx.lab })}`, req);
        await reload();
        showAlert("Column saved.", "ok");
    }

    async function deleteColumn(id) {
        const ok = await askConfirm({
            title: "Remove column",
            message: "Remove this column from the template? Existing insights keep their data; this only changes the template layout.",
            okText: "Remove",
            danger: true
        });
        if (!ok) return;
        await postJson(`${apiBase}/Notes/TemplateColumnDelete?${q({ lab: ctx.lab, id })}`);
        await reload();
        showAlert("Column removed.", "ok");
    }

    async function createTemplate() {
        const name = await askName({
            title: "New template",
            label: "Template name",
            value: "Key Insights & Highlights",
            hint: "This name appears in the template list and on the report Insights panel.",
            okText: "Create"
        });
        if (!name) return;
        const result = await postJson(`${apiBase}/Notes/TemplateSave?${q({ lab: ctx.lab })}`, {
            reportName: ctx.reportName,
            templateName: name,
            isActive: true
        });
        await reload(result && result.id);
        showAlert("Template created.", "ok");
    }

    async function addColumn() {
        if (!selected) return;
        const name = await askName({
            title: "Add column",
            label: "Column name",
            value: "",
            hint: "Use the same labels as the Key Insights Excel sheet when possible.",
            okText: "Add"
        });
        if (!name) return;
        const next = (selected.columns || []).reduce((m, c) => Math.max(m, c.sortOrder || 0), 0) + 1;
        await postJson(`${apiBase}/Notes/TemplateColumnSave?${q({ lab: ctx.lab })}`, {
            templateId: selected.templateId,
            columnName: name,
            columnType: "Text",
            sortOrder: next
        });
        await reload(selected.templateId);
    }

    async function seedColumns() {
        if (!selected) {
            const created = await postJson(`${apiBase}/Notes/TemplateSave?${q({ lab: ctx.lab })}`, {
                reportName: ctx.reportName,
                templateName: "Key Insights & Highlights",
                isActive: true
            });
            await reload(created && created.id);
        }
        if (!selected) return;
        for (const col of SEED_COLUMNS) {
            await postJson(`${apiBase}/Notes/TemplateColumnSave?${q({ lab: ctx.lab })}`, {
                templateId: selected.templateId,
                ...col
            });
        }
        await reload(selected.templateId);
        showAlert("Key Insights & Highlights columns seeded.", "ok");
    }

    async function reload(keepId) {
        const data = await getJson(`${apiBase}/Notes/Templates?${q({ lab: ctx.lab, report: ctx.reportName })}`);
        templates = data.templates || [];
        const id = keepId || (selected && selected.templateId);
        selected = templates.find(t => t.templateId === id) || (templates.length === 1 ? templates[0] : selected && templates.find(t => t.templateId === selected.templateId)) || templates[0] || null;
        renderList();
        renderEditor();
    }

    async function boot() {
        try {
            const avail = await getJson(`${apiBase}/Notes/Available?${q({ lab: ctx.lab })}`);
            if (!avail || !avail.available) {
                showAlert("Insights schema is not deployed on this lab database. Run SQL_Scripts/NotesInsights (01–08) on CoveLRN.", "error");
                el.list.innerHTML = "";
                return;
            }
            await reload();
            if (!templates.length) showAlert("No template yet. Create one and seed the Key Insights columns.", "info");
        } catch (e) {
            showAlert(e.message, "error");
        }
    }

    el.newTpl.onclick = () => createTemplate().catch(e => showAlert(e.message, "error"));
    el.addCol.onclick = () => addColumn().catch(e => showAlert(e.message, "error"));
    el.seed.onclick = () => seedColumns().catch(e => showAlert(e.message, "error"));
    boot();
})();
