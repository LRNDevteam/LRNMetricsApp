namespace LabMetricsDashboard.Models;

/// <summary>A row of LRNMaster.dbo.DenialCategoryMaster (sheet 1 of the denial codes workbook).</summary>
public sealed record DenialCategoryMasterRow(
    int Id, string DenialCode, string? Description, string? ActionCategory, DateTime CreatedOn, string? CreatedBy);

/// <summary>A row of LRNMaster.dbo.NonCollectibleDenialMaster (sheet "Non-collectible Denials").</summary>
public sealed record NonCollectibleDenialRow(
    int Id, string DenialCode, string? Description, DateTime CreatedOn, string? CreatedBy);

/// <summary>Which of the two masters a single add / edit / delete applies to.</summary>
public enum DenialMasterKind { Category, NonCollectible }

/// <summary>One denial code read from the workbook, before it is saved.</summary>
public sealed record DenialCodeImportRow(string DenialCode, string? Description, string? ActionCategory);

/// <summary>
/// What was read from one sheet. <see cref="Rows"/> is null when the workbook has no such sheet,
/// so that table is left as it is rather than emptied.
/// </summary>
public sealed class DenialSheetImport
{
    public string? SheetName { get; init; }
    public List<DenialCodeImportRow>? Rows { get; init; }
    /// <summary>Codes that appeared again further down the sheet; the first row was kept.</summary>
    public List<string> Duplicates { get; init; } = new();
    public int BlankCodeRows { get; init; }
}

public sealed class DenialCategoryWorkbookImport
{
    public DenialSheetImport Categories { get; init; } = new();
    public DenialSheetImport NonCollectible { get; init; } = new();
    /// <summary>Why the workbook cannot be imported at all, or null when at least one sheet was read.</summary>
    public string? Error { get; init; }
}

public sealed class DenialCategoryMasterViewModel
{
    public IReadOnlyList<DenialCategoryMasterRow> Categories { get; init; } = Array.Empty<DenialCategoryMasterRow>();
    public IReadOnlyList<NonCollectibleDenialRow> NonCollectible { get; init; } = Array.Empty<NonCollectibleDenialRow>();
    public bool CanImport { get; init; }
    public string ActiveTab { get; init; } = "categories";
    /// <summary>Set when the master tables are not installed yet (DenialCategoryMaster_Setup.sql).</summary>
    public string? SetupError { get; init; }
}
