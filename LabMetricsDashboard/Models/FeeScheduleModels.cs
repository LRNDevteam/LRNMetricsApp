namespace LabMetricsDashboard.Models;

/// <summary>One row of LRNMaster.dbo.FeeSchedule.</summary>
public sealed record FeeScheduleRow(
    int Id,
    string Hcpcs,
    decimal Rate,
    string? Modifier,
    int? FeeYear,
    DateTime? EffectiveDate,
    string? Indicator,
    string? ShortDescription,
    string? SourceFile,
    DateTime ImportedOn,
    string? ImportedBy);

/// <summary>One HCPCS read from an imported fee schedule file.</summary>
public sealed record FeeScheduleImportRow(
    string Hcpcs,
    decimal Rate,
    string? Modifier,
    int? FeeYear,
    DateTime? EffectiveDate,
    string? Indicator,
    string? ShortDescription);

/// <summary>What a fee schedule file contained, before anything is saved.</summary>
public sealed class FeeScheduleFileImport
{
    /// <summary>Set when the file cannot be imported at all; nothing is saved.</summary>
    public string? Error { get; init; }

    /// <summary>One row per HCPCS, in file order.</summary>
    public IReadOnlyList<FeeScheduleImportRow> Rows { get; init; } = Array.Empty<FeeScheduleImportRow>();

    /// <summary>Rows that repeated an HCPCS already read (e.g. the CLFS "QW" modifier rows).</summary>
    public int DuplicateRows { get; init; }

    /// <summary>HCPCS codes listed more than once with DIFFERENT rates; the row without a modifier (else the first) is kept.</summary>
    public IReadOnlyList<string> ConflictingRates { get; init; } = Array.Empty<string>();

    public int BlankHcpcsRows { get; init; }

    /// <summary>"HCPCS (row n): value" for rates that are missing, not a number or negative. Those rows are skipped.</summary>
    public IReadOnlyList<string> InvalidRates { get; init; } = Array.Empty<string>();

    public string? SheetName { get; init; }
}

public sealed class FeeScheduleViewModel
{
    public IReadOnlyList<FeeScheduleRow> Rows { get; init; } = Array.Empty<FeeScheduleRow>();
    public bool CanImport { get; init; }
    public string? SetupError { get; init; }
}
