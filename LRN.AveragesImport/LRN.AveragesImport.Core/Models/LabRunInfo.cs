namespace LRN.AveragesImport.Core.Models;

/// <summary>
/// One successful run from sp_GetRecentSuccessRunByLab, already resolved
/// against the configured lab mapping (LabId + FolderName).
/// </summary>
public sealed class LabRunInfo
{
    public required string RunId { get; init; }

    /// <summary>Lab name as reported by the stored procedure (e.g. "Augustus Labs").</summary>
    public required string LabName { get; init; }

    /// <summary>Numeric lab id from the config mapping — written to CPTAverage.LabID / PanelAverage.LabId.</summary>
    public required int LabId { get; init; }

    /// <summary>On-disk folder name from the config mapping (e.g. "Augustus").</summary>
    public required string FolderName { get; init; }

    public DateTime? StartTimeIst { get; init; }
    public DateTime? EndTimeIst { get; init; }
}
