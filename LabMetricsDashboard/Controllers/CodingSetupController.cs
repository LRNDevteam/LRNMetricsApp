using System.Globalization;
using System.Text;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>Coding Setup – lab-specific CRUD for Panel/Pathogen/CPT master combinations.</summary>
public class CodingSetupController : Controller
{
    private readonly ICodingSetupRepository _repo;
    private readonly LabSettings _labSettings;
    private readonly ILogger<CodingSetupController> _logger;

    public CodingSetupController(
        ICodingSetupRepository repo,
        LabSettings labSettings,
        ILogger<CodingSetupController> logger)
    {
        _repo = repo;
        _labSettings = labSettings;
        _logger = logger;
    }

    // ?? Master List ????????????????????????????????????????????????

    // GET /CodingSetup?lab=X
    public async Task<IActionResult> Index(
        string? lab, string? search,
        string sortColumn = "PanelName", string sortDirection = "asc",
        string activeFilter = "active", int page = 1, CancellationToken ct = default)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        var selectedLab = LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);

        var (records, totalCount) = await _repo.GetPagedAsync(
            selectedLab, search, sortColumn, sortDirection, activeFilter, page, 20, ct);

        var grouped = records
            .GroupBy(r => $"{r.PanelName}\0{r.TestName ?? ""}\0{r.PathogenName}", StringComparer.OrdinalIgnoreCase)
            .Select(g => new CodingSetupPanelWiseRow
            {
                PanelName = g.First().PanelName,
                TestName = g.First().TestName,
                PathogenName = g.First().PathogenName,
                Procedure = string.Join(",", g.OrderBy(r => r.CPTCode).Select(r => $"{r.CPTCode}*{r.DefaultUnits}")),
                DefaultICDCodes = g.Select(r => r.DefaultICDCodes).FirstOrDefault(i => !string.IsNullOrWhiteSpace(i)),
                SortOrder = g.Min(r => r.SortOrder),
                IsActive = g.All(r => r.IsActive),
                RecordIds = g.Select(r => r.Id).ToList()
            })
            .ToList();

        var vm = new CodingSetupIndexViewModel
        {
            LabName = selectedLab,
            AvailableLabs = availableLabs,
            Records = records,
            GroupedRecords = grouped,
            TotalCount = totalCount,
            Page = page,
            Search = search,
            SortColumn = sortColumn,
            SortDirection = sortDirection,
            ActiveFilter = activeFilter
        };

        ViewData["Title"] = "Coding Setup";
        ViewData["SelectedLab"] = selectedLab;
        return View(vm);
    }

    // ?? Lookups API ????????????????????????????????????????????????

    /// <summary>Returns distinct dropdown values for the Create / Edit forms.</summary>
    [HttpGet]
    public async Task<IActionResult> Lookups(string lab, CancellationToken ct)
    {
        var selectedLab = ResolveLab(lab);
        var lookups = await _repo.GetDropdownLookupsAsync(selectedLab, ct);
        return Json(lookups);
    }

    // ?? Panel Details API ???????????????????????????????????????????

    /// <summary>Returns tests, pathogens, and CPT codes for an existing panel from the master PanelPathogenCPTlist.</summary>
    [HttpGet]
    public async Task<IActionResult> PanelDetails(string lab, string panelName, CancellationToken ct)
    {
        // Query master PanelPathogenCPTlist (source of truth for panel definitions)
        var records = await _repo.GetMasterPanelDetailsAsync(panelName, ct);

        // Fall back to lab-specific CodingSetupMasterList if master has no data
        if (records.Count == 0)
        {
            var selectedLab = ResolveLab(lab);
            records = await _repo.GetByPanelNameAsync(selectedLab, panelName, ct);
        }

        var result = new
        {
            records = records.Select(r => new { panelName = r.PanelName, testName = r.TestName, pathogenName = r.PathogenName, cptCode = r.CPTCode, units = r.DefaultUnits }).ToList(),
            tests = records.Select(r => r.TestName).Where(t => !string.IsNullOrWhiteSpace(t)).Distinct().ToList(),
            pathogens = records.Select(r => r.PathogenName).Distinct().ToList(),
            cptEntries = records
                .GroupBy(r => r.CPTCode, StringComparer.OrdinalIgnoreCase)
                .Select(g => new { cptCode = g.Key, units = g.First().DefaultUnits })
                .ToList(),
            defaultIcdCodes = records.Select(r => r.DefaultICDCodes).FirstOrDefault(i => !string.IsNullOrWhiteSpace(i))
        };
        return Json(result);
    }

    // ?? Create ?????????????????????????????????????????????????????

    // GET /CodingSetup/Create?lab=X
    public async Task<IActionResult> Create(string lab, CancellationToken ct)
    {
        var selectedLab = ResolveLab(lab);
        var lookups = await _repo.GetDropdownLookupsAsync(selectedLab, ct);
        ViewBag.PanelNames = lookups.PanelNames;
        ViewBag.Lookups = lookups;
        ViewData["Title"] = "New Combination";
        ViewData["SelectedLab"] = selectedLab;
        return View(new CodingSetupMultiCreateModel { LabName = selectedLab });
    }

    // POST /CodingSetup/Create
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Create(CodingSetupMultiCreateModel model, CancellationToken ct)
    {
        // Validate
        if (string.IsNullOrWhiteSpace(model.LabName))
            ModelState.AddModelError(nameof(model.LabName), "Lab is required.");
        if (string.IsNullOrWhiteSpace(model.PanelName))
            ModelState.AddModelError(nameof(model.PanelName), "Panel Name is required.");
        if (string.IsNullOrWhiteSpace(model.PathogenName))
            ModelState.AddModelError(nameof(model.PathogenName), "Pathogen Name is required.");

        var validEntries = model.CptEntries
            .Where(e => !string.IsNullOrWhiteSpace(e.CptCode))
            .ToList();

        if (validEntries.Count == 0)
            ModelState.AddModelError("", "At least one CPT Code is required.");

        foreach (var entry in validEntries)
        {
            if (entry.Units <= 0)
            {
                ModelState.AddModelError("", $"Units for CPT '{entry.CptCode}' must be greater than 0.");
                break;
            }
        }

        if (!ModelState.IsValid) return await ReturnMultiCreateView(model, ct);

        // Check duplicates and create
        var duplicates = new List<string>();
        var created = 0;
        foreach (var entry in validEntries)
        {
            var cpt = entry.CptCode.Trim();
            if (await _repo.ExistsDuplicateAsync(model.LabName, model.PanelName, model.TestName,
                    model.PathogenName, cpt, ct: ct))
            {
                duplicates.Add(cpt);
                continue;
            }

            var form = new CodingSetupFormModel
            {
                LabName = model.LabName,
                PanelName = model.PanelName,
                TestName = model.TestName,
                PathogenName = model.PathogenName,
                CPTCode = cpt,
                DefaultUnits = entry.Units,
                DefaultICDCodes = model.DefaultICDCodes,
                SortOrder = model.SortOrder,
                IsActive = model.IsActive
            };
            await _repo.CreateAsync(form, User.Identity?.Name, ct);
            created++;
        }

        if (duplicates.Count > 0 && created == 0)
        {
            ModelState.AddModelError("", $"All CPT codes already exist: {string.Join(", ", duplicates)}");
            return await ReturnMultiCreateView(model, ct);
        }

        var msg = $"Created {created} combination(s) successfully.";
        if (duplicates.Count > 0)
            msg += $" Skipped {duplicates.Count} duplicate(s): {string.Join(", ", duplicates)}.";
        TempData["Success"] = msg;
        return RedirectToAction(nameof(Index), new { lab = model.LabName });
    }

    // ?? Edit ???????????????????????????????????????????????????????

    // GET /CodingSetup/Edit/5
    public async Task<IActionResult> Edit(int id, string? lab, CancellationToken ct)
    {
        var selectedLab = ResolveLab(lab);
        var record = await _repo.GetByIdAsync(selectedLab, id, ct);
        if (record is null) return NotFound();

        var lookups = await _repo.GetDropdownLookupsAsync(record.LabName, ct);
        ViewBag.PanelNames = lookups.PanelNames;
        ViewBag.Lookups = lookups;
        ViewBag.AuditHistory = await _repo.GetAuditHistoryAsync(record.LabName, id, ct);
        ViewData["Title"] = "Edit Combination";
        ViewData["SelectedLab"] = record.LabName;

        var form = new CodingSetupFormModel
        {
            Id = record.Id,
            LabName = record.LabName,
            PanelName = record.PanelName,
            TestName = record.TestName,
            PathogenName = record.PathogenName,
            CPTCode = record.CPTCode,
            DefaultUnits = record.DefaultUnits,
            DefaultICDCodes = record.DefaultICDCodes,
            SortOrder = record.SortOrder,
            IsActive = record.IsActive
        };
        ViewBag.Record = record;
        return View(form);
    }

    // POST /CodingSetup/Edit
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Edit(CodingSetupFormModel model, CancellationToken ct)
    {
        if (!ValidateForm(model)) return await ReturnEditView(model, ct);

        if (await _repo.ExistsDuplicateAsync(model.LabName, model.PanelName, model.TestName,
                model.PathogenName, model.CPTCode, model.Id, ct))
        {
            ModelState.AddModelError("", "This Panel / Test / Pathogen / CPT combination already exists for this lab.");
            return await ReturnEditView(model, ct);
        }

        await _repo.UpdateAsync(model, User.Identity?.Name, ct);
        TempData["Success"] = "Combination updated successfully.";
        return RedirectToAction(nameof(Index), new { lab = model.LabName });
    }

    // ?? Deactivate (Soft Delete) ???????????????????????????????????

    // POST /CodingSetup/Deactivate/5
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Deactivate(int id, string? lab, CancellationToken ct)
    {
        await _repo.DeactivateAsync(lab ?? "", id, User.Identity?.Name, ct);
        TempData["Success"] = "Record deactivated.";
        return RedirectToAction(nameof(Index), new { lab });
    }

    // ?? Clone Panel ????????????????????????????????????????????????

    // GET /CodingSetup/Clone?lab=X
    public async Task<IActionResult> Clone(string lab, CancellationToken ct)
    {
        var selectedLab = ResolveLab(lab);
        ViewBag.PanelNames = await _repo.GetDistinctPanelNamesAsync(selectedLab, ct);
        ViewData["Title"] = "Clone Panel";
        ViewData["SelectedLab"] = selectedLab;
        return View(new ClonePanelRequest { LabName = selectedLab });
    }

    // POST /CodingSetup/Clone
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Clone(ClonePanelRequest model, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(model.SourcePanelName) || string.IsNullOrWhiteSpace(model.NewPanelName))
        {
            ModelState.AddModelError("", "Both source and new panel names are required.");
            ViewBag.PanelNames = await _repo.GetDistinctPanelNamesAsync(model.LabName, ct);
            ViewData["SelectedLab"] = model.LabName;
            return View(model);
        }

        var count = await _repo.ClonePanelAsync(model.LabName, model.SourcePanelName,
            model.NewPanelName, User.Identity?.Name, ct);
        TempData["Success"] = $"Cloned {count} combinations to '{model.NewPanelName}'.";
        return RedirectToAction(nameof(Index), new { lab = model.LabName });
    }

    // ?? Export ??????????????????????????????????????????????????????

    // GET /CodingSetup/ExportExcel?lab=X
    public async Task<IActionResult> ExportExcel(string lab, string? search,
        string activeFilter = "active", CancellationToken ct = default)
    {
        var selectedLab = ResolveLab(lab);
        var records = await _repo.GetAllAsync(selectedLab, search, activeFilter, ct);

        // Build Coding Master format: aggregate CPTs into procedure strings per panel
        var outputRows = records
            .GroupBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase)
            .Select(g =>
            {
                var procedureParts = g
                    .GroupBy(r => r.CPTCode, StringComparer.OrdinalIgnoreCase)
                    .Select(cg => $"{cg.Key}*{cg.First().DefaultUnits:G29}")
                    .ToList();
                var procedure = string.Join(",", procedureParts);
                return new { PanelName = g.Key, Procedure = procedure };
            })
            .OrderBy(r => r.PanelName, StringComparer.OrdinalIgnoreCase)
            .ToList();

        using var wb = new XLWorkbook();
        var ws = wb.Worksheets.Add("CodingMaster");

        // Header style
        var headerBg = XLColor.FromHtml("#1B3A4B");
        string[] headers = ["S.No", "Production Panel Name", "Coding Master Panel name",
            "Payer", "Payer_Common_Code", "Procedure", "Total Billed Charge"];
        for (int i = 0; i < headers.Length; i++)
        {
            var cell = ws.Cell(1, i + 1);
            cell.Value = headers[i];
            cell.Style.Font.Bold = true;
            cell.Style.Font.FontColor = XLColor.White;
            cell.Style.Fill.BackgroundColor = headerBg;
            cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
        }
        ws.SheetView.FreezeRows(1);
        ws.Range(1, 1, 1, headers.Length).SetAutoFilter();

        int rowIdx = 2;
        int sno = 1;
        foreach (var panel in outputRows)
        {
            var productionName = GetProductionPanelName(panel.PanelName);

            ws.Cell(rowIdx, 1).Value = sno++;
            ws.Cell(rowIdx, 2).Value = productionName;
            ws.Cell(rowIdx, 3).Value = panel.PanelName;
            ws.Cell(rowIdx, 4).Value = "All other Insurance";
            ws.Cell(rowIdx, 5).Value = "Commercial";
            ws.Cell(rowIdx, 6).Value = panel.Procedure;
            ws.Cell(rowIdx, 7).Value = 0;
            ws.Cell(rowIdx, 7).Style.NumberFormat.Format = "#,##0.00";
            rowIdx++;
        }

        ws.Column(1).Width = 6;
        ws.Column(2).Width = 26;
        ws.Column(3).Width = 30;
        ws.Column(4).Width = 24;
        ws.Column(5).Width = 22;
        ws.Column(6).Width = 80;
        ws.Column(7).Width = 20;

        using var ms = new MemoryStream();
        wb.SaveAs(ms);
        return File(ms.ToArray(),
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            $"CodingMaster_{selectedLab}_{DateTime.Now:yyyyMMdd_HHmmss}.xlsx");
    }

    // GET /CodingSetup/ExportCsv?lab=X
    public async Task<IActionResult> ExportCsv(string lab, string? search,
        string activeFilter = "active", CancellationToken ct = default)
    {
        var selectedLab = ResolveLab(lab);
        var records = await _repo.GetAllAsync(selectedLab, search, activeFilter, ct);
        var sb = new StringBuilder();
        sb.AppendLine("PanelName,TestName,PathogenName,CPTCode,DefaultUnits,DefaultICDCodes,SortOrder,IsActive");
        foreach (var r in records)
        {
            sb.AppendLine(string.Join(",",
                Esc(r.PanelName), Esc(r.TestName), Esc(r.PathogenName), Esc(r.CPTCode),
                r.DefaultUnits, Esc(r.DefaultICDCodes), r.SortOrder, r.IsActive ? "Yes" : "No"));
        }

        return File(Encoding.UTF8.GetBytes(sb.ToString()), "text/csv",
            $"CodingSetup_{selectedLab}_{DateTime.Now:yyyyMMdd_HHmmss}.csv");
    }

    // ?? Bulk Import from CSV ???????????????????????????????????????

    // GET /CodingSetup/Import?lab=X
    public IActionResult Import(string lab)
    {
        var selectedLab = ResolveLab(lab);
        ViewData["Title"] = "Bulk Import CSV";
        ViewData["SelectedLab"] = selectedLab;
        ViewBag.LabName = selectedLab;
        return View();
    }

    // POST /CodingSetup/Import
    [HttpPost, ValidateAntiForgeryToken]
    public async Task<IActionResult> Import(string lab, IFormFile? csvFile, CancellationToken ct)
    {
        var selectedLab = ResolveLab(lab);

        if (csvFile is null || csvFile.Length == 0)
        {
            TempData["Error"] = "Please select a CSV file.";
            return RedirectToAction(nameof(Import), new { lab = selectedLab });
        }

        var records = new List<CodingSetupFormModel>();
        using var stream = csvFile.OpenReadStream();
        using var reader = new StreamReader(stream);

        // Skip header
        var header = await reader.ReadLineAsync(ct);
        if (string.IsNullOrWhiteSpace(header))
        {
            TempData["Error"] = "CSV file is empty.";
            return RedirectToAction(nameof(Import), new { lab = selectedLab });
        }

        var lineNum = 1;
        while (await reader.ReadLineAsync(ct) is { } line)
        {
            lineNum++;
            if (string.IsNullOrWhiteSpace(line)) continue;

            var cols = ParseCsvLine(line);
            if (cols.Length < 6)
            {
                TempData["Error"] = $"Line {lineNum}: expected at least 6 columns (PanelName,TestName,PathogenName,CPTCode,DefaultUnits,DefaultICDCodes).";
                return RedirectToAction(nameof(Import), new { lab = selectedLab });
            }

            records.Add(new CodingSetupFormModel
            {
                LabName = selectedLab,
                PanelName = cols[0].Trim(),
                TestName = string.IsNullOrWhiteSpace(cols[1]) ? null : cols[1].Trim(),
                PathogenName = cols[2].Trim(),
                CPTCode = cols[3].Trim(),
                DefaultUnits = decimal.TryParse(cols[4].Trim(), CultureInfo.InvariantCulture, out var u) && u > 0 ? u : 1,
                DefaultICDCodes = cols.Length > 5 ? cols[5].Trim() : null,
                SortOrder = cols.Length > 6 && int.TryParse(cols[6].Trim(), out var so) ? so : 0,
                IsActive = cols.Length <= 7 || !cols[7].Trim().Equals("No", StringComparison.OrdinalIgnoreCase)
            });
        }

        var imported = await _repo.BulkImportAsync(selectedLab, records, User.Identity?.Name, ct);
        TempData["Success"] = $"Imported {imported} new records ({records.Count - imported} duplicates skipped).";
        return RedirectToAction(nameof(Index), new { lab = selectedLab });
    }

    // ?? Helpers ????????????????????????????????????????????????????

    private string ResolveLab(string? lab)
    {
        var availableLabs = _labSettings.Labs.Keys.OrderBy(x => x).ToList();
        return LabSelectionHelper.Resolve(HttpContext, lab, availableLabs);
    }

    private bool ValidateForm(CodingSetupFormModel m)
    {
        if (string.IsNullOrWhiteSpace(m.LabName))
            ModelState.AddModelError(nameof(m.LabName), "Lab is required.");
        if (string.IsNullOrWhiteSpace(m.PanelName))
            ModelState.AddModelError(nameof(m.PanelName), "Panel Name is required.");
        if (string.IsNullOrWhiteSpace(m.PathogenName))
            ModelState.AddModelError(nameof(m.PathogenName), "Pathogen Name is required.");
        if (string.IsNullOrWhiteSpace(m.CPTCode))
            ModelState.AddModelError(nameof(m.CPTCode), "CPT Code is required.");
        if (m.DefaultUnits <= 0)
            ModelState.AddModelError(nameof(m.DefaultUnits), "Units must be greater than 0.");
        return ModelState.IsValid;
    }

    private async Task<IActionResult> ReturnMultiCreateView(CodingSetupMultiCreateModel model, CancellationToken ct)
    {
        var lookups = await _repo.GetDropdownLookupsAsync(model.LabName, ct);
        ViewBag.PanelNames = lookups.PanelNames;
        ViewBag.Lookups = lookups;
        ViewData["Title"] = "New Combination";
        ViewData["SelectedLab"] = model.LabName;
        return View("Create", model);
    }

    private async Task<IActionResult> ReturnEditView(CodingSetupFormModel model, CancellationToken ct)
    {
        var lookups = await _repo.GetDropdownLookupsAsync(model.LabName, ct);
        ViewBag.PanelNames = lookups.PanelNames;
        ViewBag.Lookups = lookups;
        ViewBag.AuditHistory = await _repo.GetAuditHistoryAsync(model.LabName, model.Id, ct);
        ViewData["Title"] = "Edit Combination";
        ViewData["SelectedLab"] = model.LabName;
        return View("Edit", model);
    }

    private static string Esc(string? val) => $"\"{val?.Replace("\"", "\"\"") ?? ""}\"";

    /// <summary>Maps Coding Master Panel Name to Production Panel Name.</summary>
    private static readonly Dictionary<string, string> ProductionPanelMap = new(StringComparer.OrdinalIgnoreCase)
    {
        ["GI Panel"] = "GI",
        ["RPP Panel"] = "RPP",
        ["RPP + ABR"] = "RPP",
        ["RPP Panel + ABR"] = "RPP",
        ["UTI"] = "UTI",
        ["UTI + ABR"] = "UTI",
        ["STI"] = "STI",
        ["Womens Health"] = "WOMEN'S HEALTH",
        ["Womens Health + ABR"] = "WOMEN'S HEALTH",
        ["Nail-87798"] = "Nail-87798",
        ["Nail-87798 + ABR"] = "Nail-87798",
        ["Nail-87801"] = "Nail-87801",
        ["Wound-87798"] = "WOUND",
        ["Wound-87798 + ABR"] = "WOUND",
        ["Wound-87801"] = "WOUND",
        ["Wound + ABR-87801"] = "WOUND",
    };

    private static string GetProductionPanelName(string codingMasterPanelName)
        => ProductionPanelMap.TryGetValue(codingMasterPanelName, out var prod) ? prod : codingMasterPanelName;

    private static string[] ParseCsvLine(string line)
    {
        var fields = new List<string>();
        var current = new StringBuilder();
        var inQuotes = false;

        for (int i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (inQuotes)
            {
                if (c == '"' && i + 1 < line.Length && line[i + 1] == '"')
                {
                    current.Append('"');
                    i++;
                }
                else if (c == '"')
                {
                    inQuotes = false;
                }
                else
                {
                    current.Append(c);
                }
            }
            else
            {
                if (c == '"') inQuotes = true;
                else if (c == ',')
                {
                    fields.Add(current.ToString());
                    current.Clear();
                }
                else current.Append(c);
            }
        }
        fields.Add(current.ToString());
        return fields.ToArray();
    }
}
