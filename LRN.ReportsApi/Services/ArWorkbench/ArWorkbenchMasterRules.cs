using LRN.ReportsApi.Models;

namespace LRN.ReportsApi.Services.ArWorkbench;

/// <summary>A column that stores a value from a master list as plain text - what the usage count counts.</summary>
public sealed record ArWorkbenchMasterUsage(string Table, string Column, string? Filter = null);

/// <summary>
/// One editable dbo.ARWB_MasterListItem list. <see cref="MaxLength"/> is the width of the narrowest
/// column that stores the value, so a value that saves here can always be picked and saved there.
/// </summary>
public sealed record ArWorkbenchMasterType(
    string Key,
    string Label,
    string Description,
    int MaxLength,
    bool IsCodeList,
    string? UsageLabel,
    IReadOnlyList<ArWorkbenchMasterUsage> Usage,
    IReadOnlyList<string> ReservedValues,
    string? FormatHint = null);

public sealed record ArWorkbenchMasterValidated(string Value, int? SortOrder, bool IsActive);

public sealed record ArWorkbenchMasterValidation(string? Error, ArWorkbenchMasterValidated? Result)
{
    public static ArWorkbenchMasterValidation Fail(string error) => new(error, null);
}

public sealed record ArWorkbenchDenialCodeValidated(string DenialCode, string DenialCategory, string? DenialReason, bool IsActive);

public sealed record ArWorkbenchDenialCodeValidation(string? Error, ArWorkbenchDenialCodeValidated? Result)
{
    public static ArWorkbenchDenialCodeValidation Fail(string error) => new(error, null);
}

/// <summary>One data row of an imported Denial Code Master workbook, as text (RowNumber is the Excel row).</summary>
public sealed record ArWorkbenchDenialCodeImportRow(int RowNumber, string? DenialCode, string? DenialCategory, string? DenialReason, string? Active);

public enum ArWorkbenchSaveStatus { Ok, NotFound, Conflict, Invalid }

public sealed record ArWorkbenchSaveResult(ArWorkbenchSaveStatus Status, string Message)
{
    public static ArWorkbenchSaveResult Ok(string message) => new(ArWorkbenchSaveStatus.Ok, message);
    public static ArWorkbenchSaveResult NotFound(string message) => new(ArWorkbenchSaveStatus.NotFound, message);
    public static ArWorkbenchSaveResult Conflict(string message) => new(ArWorkbenchSaveStatus.Conflict, message);
    public static ArWorkbenchSaveResult Invalid(string message) => new(ArWorkbenchSaveStatus.Invalid, message);
}

/// <summary>
/// The AR Workbench master lists and the rules a value must meet - the workbench's counterpart of
/// <see cref="WorkflowMasterValueRules"/>, with the same behaviour: duplicates are compared with
/// spacing, hyphens and slashes ignored; a value stored by workbench records cannot be renamed or
/// deleted (deactivate it instead); a list always keeps one active value. Free of SQL so it can be
/// unit-tested.
/// </summary>
public static class ArWorkbenchMasterRules
{
    public const int MaxSortOrder = 1_000_000;
    public const int DenialCodeMaxLength = 50;
    public const int DenialCategoryMaxLength = 200;
    public const int DenialReasonMaxLength = 1000;

    /// <summary>The list that the denial code map's categories come from.</summary>
    public const string DenialCategoryType = "DENIAL_CATEGORY";

    /// <summary>
    /// The claim sync's fallback category for a denied claim whose code is not mapped
    /// (dbo.ARWB_usp_LoadClaimsFromSource), so it is always a valid category.
    /// </summary>
    public const string FallbackDenialCategory = "Other";

    private const string CodeHint = "A denial code, e.g. 197 or CO-197 (stored as 197)";

    private static ArWorkbenchMasterUsage[] FollowUp(string column) => [new("dbo.ARWB_ClaimFollowUp", column)];

    // ListType keys are rows in dbo.ARWB_MasterListItem; they are data and must not be renamed.
    // Order is the order the screen lists them in. Usage tables/columns are constants spliced into
    // SQL - never request input.
    public static readonly IReadOnlyList<ArWorkbenchMasterType> Types =
    [
        new("NON_COLLECTIBLE_CODE", "Non-Collectible Denial Codes", "A claim whose primary denial is on this list goes to the Non-Collectible sub-queues.",
            DenialCodeMaxLength, true, null, [], [], CodeHint),
        new("AUTO_ADJUST_CODE", "Auto-Adjust Denial Codes", "Denials on this list are adjusted rather than followed up.",
            DenialCodeMaxLength, true, null, [], [], CodeHint),
        new(DenialCategoryType, "Denial Categories", "The category a denial code maps to. Drives the claim's workflow template and recommended action.",
            DenialCategoryMaxLength, false, "claims and denial code mappings",
            [new("dbo.ARWB_Claim", "DenialCategory"), new("dbo.ARWB_DenialCodeCategoryMap", "DenialCategory")], [FallbackDenialCategory]),
        new("PANEL_TYPE", "Panel Types", "Panel types offered for claims.",
            400, false, "claims", [new("dbo.ARWB_Claim", "PanelType")], []),
        new("DENIAL_ROOT_CAUSE", "Denial Root Cause Options", "Root cause captured on a follow-up note when the claim status is Denied.",
            400, false, "follow-up notes", FollowUp("DenialRootCause"), []),
        new("FIX_RESOLUTION", "Fix / Resolution Options", "Fix / resolution captured on every follow-up note.",
            200, false, "follow-up notes and claim-status rules",
            [new("dbo.ARWB_ClaimFollowUp", "FixResolution"), new("dbo.ARWB_FixResolutionByStatus", "FixResolution")],
            ["CIP - Client Escalations", "Write Off"]),
        new("CLAIM_STATUS", "Follow-Up Claim Statuses", "Claim status captured on every follow-up note.",
            100, false, "follow-up notes and claim-status rules",
            [new("dbo.ARWB_ClaimFollowUp", "FollowUpClaimStatus"), new("dbo.ARWB_FixResolutionByStatus", "ClaimStatus")],
            ["Denied"]),
        new("FOLLOW_UP_TYPE", "Follow-Up Types", "How the follow-up was made.",
            50, false, "follow-up notes", FollowUp("FollowUpType"), []),
        new("CLAIM_TYPE", "Claim Types", "Primary or secondary claim on a follow-up note.",
            50, false, "follow-up notes", FollowUp("ClaimType"), []),
        new("CIP_CATEGORY", "CIP Categories", "Category of a Client Involvement Process escalation.",
            200, false, "follow-up notes and CIP cases",
            [new("dbo.ARWB_ClaimFollowUp", "CipCategory"), new("dbo.ARWB_CipCase", "CipCategory")], []),
        new("CIP_REQUIRED_INFO", "CIP Required Information", "What the client is asked to provide in a CIP escalation.",
            400, false, "follow-up notes and CIP cases",
            [new("dbo.ARWB_ClaimFollowUp", "CipRequiredInfo"), new("dbo.ARWB_CipCase", "RequiredInfo")], []),
        new("ESCALATION_REASON", "Escalation Reasons", "Reason an agent escalates a claim to a supervisor.",
            200, false, "agent requests", [new("dbo.ARWB_AgentRequest", "ReasonCategory", "RequestType = 'Escalation to Supervisor'")], []),
        new("REASSIGNMENT_REASON", "Reassignment Reasons", "Reason an agent asks for a claim to be reassigned.",
            200, false, "agent requests", [new("dbo.ARWB_AgentRequest", "ReasonCategory", "RequestType = 'Reassignment Request'")], []),
        new("DOCUMENT_CATEGORY", "Document Categories", "Category of a document attached to a follow-up note or CIP response.",
            100, false, "documents", [new("dbo.ARWB_Document", "DocumentCategory")], [])
    ];

    public static ArWorkbenchMasterType? Find(string? key) =>
        Types.FirstOrDefault(t => string.Equals(t.Key, key?.Trim(), StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Duplicate key. Text lists: upper case with spaces, hyphens and slashes removed (as the Denial
    /// Workflow lists), so "Write Off" and "Write-Off" are one value. Code lists: the normalized code,
    /// so "CO-197" and "197" are one value.
    /// </summary>
    public static string Normalize(ArWorkbenchMasterType type, string? value) =>
        type.IsCodeList
            ? NormalizeDenialCode(value) ?? string.Empty
            : (value ?? string.Empty).Trim().Replace("-", string.Empty).Replace(" ", string.Empty).Replace("/", string.Empty).ToUpperInvariant();

    public static bool IsReserved(ArWorkbenchMasterType type, string value) =>
        type.ReservedValues.Any(r => string.Equals(r, value.Trim(), StringComparison.OrdinalIgnoreCase));

    public static ArWorkbenchMasterValidation Validate(ArWorkbenchMasterType type, ArWorkbenchMasterValueSaveRequest? request)
    {
        if (request is null) return ArWorkbenchMasterValidation.Fail("A value is required.");

        var value = (request.Value ?? string.Empty).Trim();
        if (value.Length == 0) return ArWorkbenchMasterValidation.Fail($"{type.Label} value is required.");
        if (value.Any(char.IsControl)) return ArWorkbenchMasterValidation.Fail($"{type.Label} value cannot contain line breaks or control characters.");

        if (type.IsCodeList)
        {
            var codeError = DenialCodeError(value);
            if (codeError is not null) return ArWorkbenchMasterValidation.Fail(codeError);
            value = NormalizeDenialCode(value)!;
        }

        if (value.Length > type.MaxLength)
            return ArWorkbenchMasterValidation.Fail($"{type.Label} value cannot be longer than {type.MaxLength} characters.");
        if (request.SortOrder is < 0 or > MaxSortOrder)
            return ArWorkbenchMasterValidation.Fail($"Sort order must be between 0 and {MaxSortOrder:N0}.");

        return new(null, new ArWorkbenchMasterValidated(value, request.SortOrder, request.IsActive));
    }

    // ---- Denial codes -----------------------------------------------------------------------

    private static readonly string[] CarcGroupPrefixes = ["CO", "PR", "PI", "OA"];

    // dbo.ARWB_tvf_SplitDenialCodes splits a claim's code list on these, so a mapped code containing
    // one could never match a claim.
    private static readonly char[] CodeListDelimiters = [',', ';', '|', '/', '\r', '\n'];

    /// <summary>
    /// C# twin of dbo.ARWB_tvf_NormalizeDenialCode, which the claim sync uses: upper case; spaces,
    /// hyphens, colons and tabs removed; CARC group prefix CO / PR / PI / OA removed. 'PR 204',
    /// 'CO-204' and '204' are all 204; N57 stays N57. Null for a blank value or the text NULL.
    /// </summary>
    public static string? NormalizeDenialCode(string? raw)
    {
        var trimmed = (raw ?? string.Empty).Trim();
        if (trimmed.Length == 0 || string.Equals(trimmed, "NULL", StringComparison.OrdinalIgnoreCase)) return null;

        var v = trimmed.Replace(" ", string.Empty).Replace("-", string.Empty).Replace(":", string.Empty).Replace("\t", string.Empty).ToUpperInvariant();
        if (v.Length > 2 && CarcGroupPrefixes.Contains(v[..2])) v = v[2..];
        return v.Length == 0 ? null : v;
    }

    /// <summary>Why a raw code cannot be mapped, or null when it can.</summary>
    public static string? DenialCodeError(string? raw)
    {
        var trimmed = (raw ?? string.Empty).Trim();
        if (trimmed.Length == 0) return "Denial Code is required.";
        if (trimmed.IndexOfAny(CodeListDelimiters) >= 0)
            return $"\"{trimmed}\" holds more than one code. Enter one denial code per row.";
        if (trimmed.Any(char.IsControl)) return "Denial Code cannot contain control characters.";

        var code = NormalizeDenialCode(trimmed);
        if (code is null) return "Denial Code is required.";
        if (code.Length > DenialCodeMaxLength) return $"Denial Code cannot be longer than {DenialCodeMaxLength} characters.";
        return null;
    }

    /// <summary>
    /// Shape checks for one code-map row. Whether the category is on the Denial Categories list is
    /// checked by the repository, which reads the list.
    /// </summary>
    public static ArWorkbenchDenialCodeValidation ValidateDenialCode(ArWorkbenchDenialCodeSaveRequest? request)
    {
        if (request is null) return ArWorkbenchDenialCodeValidation.Fail("A denial code is required.");

        var codeError = DenialCodeError(request.DenialCode);
        if (codeError is not null) return ArWorkbenchDenialCodeValidation.Fail(codeError);

        var category = (request.DenialCategory ?? string.Empty).Trim();
        if (category.Length == 0) return ArWorkbenchDenialCodeValidation.Fail("Denial Category is required.");
        if (category.Length > DenialCategoryMaxLength)
            return ArWorkbenchDenialCodeValidation.Fail($"Denial Category cannot be longer than {DenialCategoryMaxLength} characters.");

        var reason = string.IsNullOrWhiteSpace(request.DenialReason) ? null : request.DenialReason.Trim();
        if (reason is { Length: > DenialReasonMaxLength })
            return ArWorkbenchDenialCodeValidation.Fail($"Denial Reason cannot be longer than {DenialReasonMaxLength} characters.");

        return new(null, new ArWorkbenchDenialCodeValidated(NormalizeDenialCode(request.DenialCode)!, category, reason, request.IsActive));
    }

    /// <summary>Import "Active" column: blank means active.</summary>
    public static bool? ParseActive(string? text) =>
        (text ?? string.Empty).Trim().ToUpperInvariant() switch
        {
            "" or "Y" or "YES" or "1" or "TRUE" or "ACTIVE" => true,
            "N" or "NO" or "0" or "FALSE" or "INACTIVE" => false,
            _ => null
        };
}
