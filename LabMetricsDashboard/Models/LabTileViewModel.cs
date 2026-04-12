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

    /// <summary>True when LineClaimEnable is set in the lab config (gates Clinic/Sales Rep Summary).</summary>
    public bool LineClaimEnabled { get; init; }

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

    /// <summary>RunId extracted from the Claim Level file name (prefix before first underscore).</summary>
    public string? ClaimRunId { get; init; }

    /// <summary>RunId extracted from the Line Level file name.</summary>
    public string? LineRunId { get; init; }

    /// <summary>RunId extracted from the Prediction Analysis file name.</summary>
    public string? PredictionRunId { get; init; }

    /// <summary>RunId extracted from the Coding Master file name.</summary>
    public string? CodingRunId { get; init; }

    /// <summary>The primary source RunId (Claim Level). All other processes should match this.</summary>
    public string? SourceRunId => ClaimRunId;

    /// <summary>Week date range extracted from the Claim file name (e.g. "03.26.2026 to 04.01.2026").</summary>
    public string? WeekRange { get; init; }

    /// <summary>Total hours since the Claim Level file was last written.</summary>
    public double? ClaimFileAgeHours { get; init; }

    /// <summary>Total hours since the Line Level file was last written.</summary>
    public double? LineFileAgeHours { get; init; }

    /// <summary>Formatted age string for Claim file (e.g. "3 h ago" or "12 d ago").</summary>
    public string? ClaimFileAgeText => FormatAge(ClaimFileAgeHours);

    /// <summary>Formatted age string for Line file.</summary>
    public string? LineFileAgeText => FormatAge(LineFileAgeHours);

    /// <summary>True when the file age exceeds 7 days.</summary>
    public bool IsClaimAgeStale => ClaimFileAgeHours.HasValue && ClaimFileAgeHours.Value > 7 * 24;
    public bool IsLineAgeStale  => LineFileAgeHours.HasValue  && LineFileAgeHours.Value  > 7 * 24;

    private static string? FormatAge(double? totalHours)
    {
        if (!totalHours.HasValue) return null;
        var h = totalHours.Value;
        if (h < 1)  return "< 1 h ago";
        if (h < 24) return $"{(int)h} h ago";
        return $"{(int)(h / 24)} d ago";
    }

    /// <summary>True when both Claim and Line files exist but have different RunIds.</summary>
    public bool IsClaimLineMismatch => HasClaimFile && HasLineFile
                                 && !string.IsNullOrEmpty(ClaimRunId)
                                 && !string.IsNullOrEmpty(LineRunId)
                                 && !string.Equals(ClaimRunId, LineRunId, StringComparison.OrdinalIgnoreCase);

    /// <summary>True when Prediction file exists but its RunId differs from the source (Claim) RunId.</summary>
    public bool IsPredictionPending => HasPredictionFile
                                      && !string.IsNullOrEmpty(SourceRunId)
                                      && !string.IsNullOrEmpty(PredictionRunId)
                                      && !string.Equals(SourceRunId, PredictionRunId, StringComparison.OrdinalIgnoreCase);

    /// <summary>True when Coding file exists but its RunId differs from the source (Claim) RunId.</summary>
    public bool IsCodingPending => HasCodingMasterFile
                                   && !string.IsNullOrEmpty(SourceRunId)
                                   && !string.IsNullOrEmpty(CodingRunId)
                                   && !string.Equals(SourceRunId, CodingRunId, StringComparison.OrdinalIgnoreCase);

    /// <summary>True when any downstream process has a RunId mismatch.</summary>
    public bool HasAnyMismatch => IsClaimLineMismatch || IsPredictionPending || IsCodingPending;
}
