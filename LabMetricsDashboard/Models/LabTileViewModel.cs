namespace LabMetricsDashboard.Models;

/// <summary>
/// Lightweight tile shown on the Home page — no CSV data loaded, file paths only.
/// </summary>
public sealed class LabTileViewModel
{
    public string LabName { get; init; } = string.Empty;

    public bool HasClaimFile { get; init; }
    public bool HasLineFile  { get; init; }
    public bool HasPredictionFile { get; init; }
    public bool HasCodingMasterFile { get; init; }

    /// <summary>
    /// True only when <c>DBEnabled</c> is true.
    /// When false the Prediction / Forecasting links are disabled on the tile.
    /// </summary>
    public bool PredictionEnabled { get; init; }

    /// <summary>True when the lab reads prediction data from the database.</summary>
    public bool DBEnabled { get; init; }

    /// <summary>True when DBEnabled and the Reports path is configured.</summary>
    public bool CodingEnabled { get; init; }

    // Full resolved paths (used as tooltips)
    public string? ClaimFilePath { get; init; }
    public string? LineFilePath  { get; init; }
    public string? PredictionFilePath { get; init; }
    public string? CodingMasterFilePath { get; init; }

    // Just the file name for display
    public string? ClaimFileName        => ClaimFilePath        is not null ? Path.GetFileName(ClaimFilePath)        : null;
    public string? LineFileName         => LineFilePath          is not null ? Path.GetFileName(LineFilePath)          : null;
    public string? PredictionFileName   => PredictionFilePath    is not null ? Path.GetFileName(PredictionFilePath)    : null;
    public string? CodingMasterFileName => CodingMasterFilePath  is not null ? Path.GetFileName(CodingMasterFilePath)  : null;
}
