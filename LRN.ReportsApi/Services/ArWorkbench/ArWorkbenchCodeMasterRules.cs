using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>
/// Rules for the central Denial Code Master (dbo.ARWB_DenialCodeMaster): one row per normalized code
/// (<see cref="ArWorkbenchMasterRules.NormalizeDenialCode"/>), so PR4 / CO4 / PI4 all land on 4.
/// The import merge is a pure function here so it can be tested without a database.
/// </summary>
public static class ArWorkbenchCodeMasterRules
{
    public const int DescriptionMax = 1000;
    public const int ActionCategoryMax = 200;
    public const int AttributeMax = 100;

    public static (ArWorkbenchCodeMasterRow? Row, string? Error) Validate(ArWorkbenchCodeMasterSaveRequest? request)
    {
        if (request is null) return (null, "A denial code is required.");
        var codeError = ArWorkbenchMasterRules.DenialCodeError(request.DenialCode);
        if (codeError is not null) return (null, codeError);

        var row = new ArWorkbenchCodeMasterRow
        {
            DenialCode = ArWorkbenchMasterRules.NormalizeDenialCode(request.DenialCode)!,
            DenialDescription = Clean(request.DenialDescription),
            ActionCategory = Clean(request.ActionCategory),
            DenialClassification = Clean(request.DenialClassification),
            CoverageStatus = Clean(request.CoverageStatus),
            ICDComplianceStatus = Clean(request.ICDComplianceStatus),
            DenialValidity = Clean(request.DenialValidity),
            IsNonCollectible = request.IsNonCollectible,
            IsActive = request.IsActive
        };
        var lengthError = LengthError(row);
        return lengthError is null ? (row, null) : (null, lengthError);
    }

    public static string? LengthError(ArWorkbenchCodeMasterRow row)
    {
        if (row.DenialDescription is { Length: > DescriptionMax }) return $"Description cannot be longer than {DescriptionMax} characters.";
        if (row.ActionCategory is { Length: > ActionCategoryMax }) return $"Action Category cannot be longer than {ActionCategoryMax} characters.";
        foreach (var (label, value) in new[] { ("Classification", row.DenialClassification), ("Coverage Status", row.CoverageStatus),
                                               ("ICD Compliance", row.ICDComplianceStatus), ("Denial Validity", row.DenialValidity) })
        {
            if (value is { Length: > AttributeMax }) return $"{label} cannot be longer than {AttributeMax} characters.";
        }
        return null;
    }

    private static readonly HashSet<string> ExcelErrors = new(StringComparer.OrdinalIgnoreCase)
        { "#N/A", "#REF!", "#VALUE!", "#DIV/0!", "#NAME?", "#NULL!", "#NUM!" };

    /// <summary>Trims; blank and Excel error values (#N/A ...) become null, control characters spaces.</summary>
    public static string? Clean(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || ExcelErrors.Contains(value.Trim())) return null;
        var chars = value.Trim().Select(ch => char.IsControl(ch) ? ' ' : ch).ToArray();
        return new string(chars).Trim();
    }

    public static bool SameContent(ArWorkbenchCodeMasterRow a, ArWorkbenchCodeMasterRow b) =>
        a.DenialDescription == b.DenialDescription && a.ActionCategory == b.ActionCategory
        && a.DenialClassification == b.DenialClassification && a.CoverageStatus == b.CoverageStatus
        && a.ICDComplianceStatus == b.ICDComplianceStatus && a.DenialValidity == b.DenialValidity
        && a.IsNonCollectible == b.IsNonCollectible && a.IsActive == b.IsActive;

    public static ArWorkbenchCodeMasterRow Copy(ArWorkbenchCodeMasterRow r) => new()
    {
        DenialCode = r.DenialCode, DenialDescription = r.DenialDescription, ActionCategory = r.ActionCategory,
        DenialClassification = r.DenialClassification, CoverageStatus = r.CoverageStatus,
        ICDComplianceStatus = r.ICDComplianceStatus, DenialValidity = r.DenialValidity,
        IsNonCollectible = r.IsNonCollectible, IsActive = r.IsActive,
        CreatedOn = r.CreatedOn, CreatedBy = r.CreatedBy, UpdatedOn = r.UpdatedOn, UpdatedBy = r.UpdatedBy
    };

    /// <summary>
    /// Merges an import into the current master.
    ///   - A row only sets the columns its sheet has (a sheet without "Coverage Status" leaves it).
    ///     A present column with a blank cell clears that value.
    ///   - A "Non-collectible" sheet is the complete list: its codes are flagged, every other code
    ///     is unflagged. A code only on that sheet is added with the sheet's description.
    ///   - The same code twice (PR4 and CO4 are the same code): the later row wins, with a warning.
    /// Returns the rows to insert and to update; existing rows not in the file are left alone.
    /// </summary>
    public static ArWorkbenchCodeMasterMerge Merge(IReadOnlyDictionary<string, ArWorkbenchCodeMasterRow> existing, ArWorkbenchCodeMasterParsed parsed,
        ArWorkbenchCodeMasterOptions? knownValues = null)
    {
        var result = new ArWorkbenchCodeMasterMerge();
        var working = new Dictionary<string, ArWorkbenchCodeMasterRow>(StringComparer.OrdinalIgnoreCase);
        var isNew = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var seenAt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        ArWorkbenchCodeMasterRow Get(string code)
        {
            if (working.TryGetValue(code, out var row)) return row;
            if (existing.TryGetValue(code, out var current)) row = Copy(current);
            else { row = new ArWorkbenchCodeMasterRow { DenialCode = code, IsActive = true }; isNew.Add(code); }
            working[code] = row;
            return row;
        }

        foreach (var line in parsed.Rows)
        {
            result.RowsRead++;
            var where = $"{line.Sheet} row {line.Line}";
            var codeError = ArWorkbenchMasterRules.DenialCodeError(line.Code);
            if (codeError is not null) { result.Errors.Add($"{where}: {codeError}"); continue; }
            var code = ArWorkbenchMasterRules.NormalizeDenialCode(line.Code)!;

            bool? nonCollectible = null, active = null;
            if (line.Has(CodeMasterColumn.NonCollectible))
            {
                // Blank means No here (ParseActive treats blank as Yes, which suits Active only).
                var text = line.Get(CodeMasterColumn.NonCollectible);
                nonCollectible = text is null ? false : ArWorkbenchMasterRules.ParseActive(text);
                if (nonCollectible is null) { result.Errors.Add($"{where}: Non-Collectible must be Yes or No."); continue; }
            }
            if (line.Has(CodeMasterColumn.Active))
            {
                active = ArWorkbenchMasterRules.ParseActive(line.Get(CodeMasterColumn.Active));
                if (active is null) { result.Errors.Add($"{where}: Active must be Yes or No."); continue; }
            }

            var candidate = Copy(Get(code));
            // A code already seen in this file (PR4 then CO4, or a repeated row): a blank or #N/A cell
            // keeps the earlier row's value instead of clearing it.
            var repeat = seenAt.ContainsKey(code);
            void Set(CodeMasterColumn column, Action<string?> apply)
            {
                if (!line.Has(column)) return;
                var value = Clean(line.Get(column));
                if (value is null && repeat) return;
                apply(value);
            }
            Set(CodeMasterColumn.Description, v => candidate.DenialDescription = v);
            Set(CodeMasterColumn.ActionCategory, v => candidate.ActionCategory = v);
            Set(CodeMasterColumn.Classification, v => candidate.DenialClassification = v);
            Set(CodeMasterColumn.Coverage, v => candidate.CoverageStatus = v);
            Set(CodeMasterColumn.IcdCompliance, v => candidate.ICDComplianceStatus = v);
            Set(CodeMasterColumn.Validity, v => candidate.DenialValidity = v);
            if (nonCollectible is { } nc) candidate.IsNonCollectible = nc;
            if (active is { } a) candidate.IsActive = a;

            var lengthError = LengthError(candidate);
            if (lengthError is not null) { result.Errors.Add($"{where}: {lengthError}"); continue; }

            if (seenAt.TryGetValue(code, out var earlier))
                result.Warnings.Add($"{where}: code {code} ({line.Code}) is also on {earlier}; this later row is used.");
            seenAt[code] = where;
            working[code] = candidate;

            if (knownValues is not null) WarnUnknown(result, where, candidate, knownValues);
        }

        if (parsed.NonCollectibleCodes is { } ncList)
        {
            var flagged = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var (sheetLine, raw, description) in ncList)
            {
                var codeError = ArWorkbenchMasterRules.DenialCodeError(raw);
                if (codeError is not null) { result.Errors.Add($"{parsed.NonCollectibleSheet} row {sheetLine}: {codeError}"); continue; }
                var code = ArWorkbenchMasterRules.NormalizeDenialCode(raw)!;
                flagged.Add(code);
                var row = Get(code);
                row.IsNonCollectible = true;
                row.DenialDescription ??= Clean(description);
            }
            // The sheet is the whole list: unflag every other code (existing ones included).
            foreach (var code in existing.Keys.Concat(working.Keys).Distinct(StringComparer.OrdinalIgnoreCase).ToList())
            {
                if (flagged.Contains(code)) continue;
                var current = working.TryGetValue(code, out var w) ? w : existing[code];
                if (!current.IsNonCollectible) continue;
                Get(code).IsNonCollectible = false;
            }
            result.NonCollectibleCodes = flagged.Count;
        }

        foreach (var (code, row) in working)
        {
            if (isNew.Contains(code)) result.Inserts.Add(row);
            else if (!SameContent(existing[code], row)) result.Updates.Add(row);
            else result.Unchanged++;
        }
        return result;
    }

    private static void WarnUnknown(ArWorkbenchCodeMasterMerge result, string where, ArWorkbenchCodeMasterRow row, ArWorkbenchCodeMasterOptions known)
    {
        void Check(string label, string? value, List<string> list)
        {
            if (value is null || list.Count == 0) return;
            if (!list.Contains(value, StringComparer.OrdinalIgnoreCase))
                result.Warnings.Add($"{where}: {label} \"{value}\" is not on the Denial Mapper list (saved as entered).");
        }
        Check("Classification", row.DenialClassification, known.DenialClassifications);
        Check("Coverage Status", row.CoverageStatus, known.CoverageStatuses);
        Check("ICD Compliance", row.ICDComplianceStatus, known.ICDComplianceStatuses);
        Check("Denial Validity", row.DenialValidity, known.DenialValidities);
    }

    /// <summary>Lab Non-Collectible list sync: what to add and what to switch off.</summary>
    public static (List<string> ToAdd, List<string> ToDeactivate, int Unchanged) PlanNonCollectibleSync(
        IEnumerable<string> masterCodes, IEnumerable<string> labActiveCodes)
    {
        var master = new HashSet<string>(masterCodes, StringComparer.OrdinalIgnoreCase);
        var lab = new HashSet<string>(labActiveCodes, StringComparer.OrdinalIgnoreCase);
        var toAdd = master.Where(c => !lab.Contains(c)).OrderBy(SortKey).ToList();
        var toDeactivate = lab.Where(c => !master.Contains(c)).OrderBy(SortKey).ToList();
        return (toAdd, toDeactivate, master.Count(lab.Contains));
    }

    /// <summary>Numeric codes in number order, then the rest (A1, B7, N290 ...).</summary>
    public static string SortKey(string code) => code.All(char.IsDigit) ? "0" + code.PadLeft(8, '0') : "1" + code;
}

public enum CodeMasterColumn { Code, Description, ActionCategory, Classification, Coverage, IcdCompliance, Validity, NonCollectible, Active }

/// <summary>One data row of an imported sheet: only the columns the sheet has are present.</summary>
public sealed class CodeMasterImportLine
{
    public string Sheet { get; init; } = string.Empty;
    public int Line { get; init; }
    public string? Code { get; init; }
    public IReadOnlyDictionary<CodeMasterColumn, string?> Values { get; init; } = new Dictionary<CodeMasterColumn, string?>();
    public bool Has(CodeMasterColumn column) => Values.ContainsKey(column);
    public string? Get(CodeMasterColumn column) => Values.TryGetValue(column, out var v) ? v : null;
}

public sealed class ArWorkbenchCodeMasterParsed
{
    public List<CodeMasterImportLine> Rows { get; } = new();
    /// <summary>Null when the file has no Non-collectible sheet (flags then come from the rows only).</summary>
    public List<(int Line, string? Code, string? Description)>? NonCollectibleCodes { get; set; }
    public string? NonCollectibleSheet { get; set; }
}

public sealed class ArWorkbenchCodeMasterMerge
{
    public int RowsRead { get; set; }
    public int Unchanged { get; set; }
    public int NonCollectibleCodes { get; set; }
    public List<ArWorkbenchCodeMasterRow> Inserts { get; } = new();
    public List<ArWorkbenchCodeMasterRow> Updates { get; } = new();
    public List<string> Errors { get; } = new();
    public List<string> Warnings { get; } = new();
}
