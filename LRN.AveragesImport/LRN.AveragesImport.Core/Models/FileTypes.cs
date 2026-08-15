namespace LRN.AveragesImport.Core.Models;

/// <summary>
/// The two aggregates produced per lab. The name is historical — these used to be
/// CSV file types and are still the FileType values written to AverageImportLog.
/// </summary>
public static class FileTypes
{
    public const string CptAverage = "CptAverage";
    public const string PanelAverage = "PanelAverage";

    public static readonly string[] All = { CptAverage, PanelAverage };
}
