namespace RcmWatcherService.Models;

public sealed class LabConfigOptions
{
    public const string Section = "LabConfig";
    public string       LabConfigFolder { get; init; } = string.Empty;
    public List<string> Labs            { get; init; } = [];
}

public sealed class LabSettings
{
    public Dictionary<string, LabCsvConfig> Labs { get; init; } = [];
}
