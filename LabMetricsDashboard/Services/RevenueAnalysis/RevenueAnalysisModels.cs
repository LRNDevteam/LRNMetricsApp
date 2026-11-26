namespace LabMetricsDashboard.Services.RevenueAnalysis;

/// <summary>Where the dashboard's claims and lines come from.</summary>
public enum RevenueAnalysisSourceKind
{
    /// <summary>The lab database's current dbo.ClaimLevelData / dbo.LineLevelData.</summary>
    Live,

    /// <summary>A weekly CLAIMLEVEL + LINELEVEL Parquet snapshot (LRNMaster.dbo.ReportSnapshotRun).</summary>
    Snapshot
}

/// <summary>One request to build a Revenue Analysis dashboard for a lab.</summary>
public sealed record RevenueAnalysisRequest
{
    public required string LabKey { get; init; }
    public required string LabDisplayName { get; init; }
    public required RevenueAnalysisSourceKind Source { get; init; }

    /// <summary>Lab database connection string (Live only).</summary>
    public string? ConnectionString { get; init; }

    /// <summary>LRNMaster.dbo.ReportSnapshotRun.SnapshotRunId (Snapshot only).</summary>
    public long? SnapshotRunId { get; init; }

    /// <summary>Inclusive date-of-service window; null on either side means open-ended.</summary>
    public DateOnly? DosFrom { get; init; }
    public DateOnly? DosTo { get; init; }

    /// <summary>Ignore a dashboard already built today for the same lab, source and window.</summary>
    public bool Refresh { get; init; }

    public required string RequestedBy { get; init; }

    /// <summary>Same lab + source + DOS window + day = same dashboard, so it can be reused.</summary>
    public string CacheKey =>
        string.Join('|', LabKey.ToUpperInvariant(), Source, SnapshotRunId?.ToString() ?? "-",
            DosFrom?.ToString("yyyy-MM-dd") ?? "-", DosTo?.ToString("yyyy-MM-dd") ?? "-",
            DateTime.Today.ToString("yyyy-MM-dd"));
}

/// <summary>A generated dashboard on disk (persisted next to the file as {token}.json).</summary>
public sealed class RevenueAnalysisMeta
{
    public string Token { get; set; } = "";
    public string CacheKey { get; set; } = "";
    public string LabKey { get; set; } = "";
    public string LabDisplayName { get; set; } = "";
    public RevenueAnalysisSourceKind Source { get; set; }
    public long? SnapshotRunId { get; set; }
    public string SourceLabel { get; set; } = "";
    public DateOnly? DosFrom { get; set; }
    public DateOnly? DosTo { get; set; }

    /// <summary>The DOS range actually present in the data.</summary>
    public DateOnly? DataDosMin { get; set; }
    public DateOnly? DataDosMax { get; set; }

    public int Claims { get; set; }
    public int Lines { get; set; }
    public int DuplicateClaimsSkipped { get; set; }
    public int UnmatchedLinesSkipped { get; set; }
    public long CompressedBytes { get; set; }
    public long UncompressedBytes { get; set; }
    public DateTime GeneratedOnUtc { get; set; }
    public string GeneratedBy { get; set; } = "";
    public double Seconds { get; set; }
    public List<string> Warnings { get; set; } = [];

    /// <summary>File name offered on download, e.g. Cove_Revenue_Analysis_DOS_01-01-2025_to_11-24-2026.html.</summary>
    public string DownloadFileName
    {
        get
        {
            var lab = new string(LabDisplayName.Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray()).Trim('_');
            while (lab.Contains("__", StringComparison.Ordinal)) lab = lab.Replace("__", "_", StringComparison.Ordinal);
            var from = (DosFrom ?? DataDosMin)?.ToString("MM-dd-yyyy") ?? "start";
            var to = (DosTo ?? DataDosMax)?.ToString("MM-dd-yyyy") ?? "end";
            return $"{lab}_Revenue_Analysis_DOS_{from}_to_{to}.html";
        }
    }
}

public enum RevenueAnalysisJobState { Queued, Running, Done, Failed }

/// <summary>A build in progress; polled by the launcher page.</summary>
public sealed class RevenueAnalysisJob
{
    public string Id { get; init; } = Guid.NewGuid().ToString("N");
    public string LabKey { get; init; } = "";
    public string RequestedBy { get; init; } = "";
    public DateTime StartedUtc { get; init; } = DateTime.UtcNow;
    public volatile RevenueAnalysisJobState State = RevenueAnalysisJobState.Queued;
    public volatile string Message = "Queued…";
    public string? Token { get; set; }
    public string? Error { get; set; }
    public bool Reused { get; set; }
}

/// <summary>One page of the dashboard, opened in its own window from the launcher.</summary>
public sealed record RevenueAnalysisPage(string Key, string Number, string Title, string Description, string Icon);

public static class RevenueAnalysisPages
{
    /// <summary>The dashboard's pages, in its own sidebar order. Keys are the template's #hash routes.</summary>
    public static readonly IReadOnlyList<RevenueAnalysisPage> All =
    [
        new("overview", "01", "Account Overview", "How every billed dollar breaks down, and the headline numbers.", "bi-speedometer2"),
        new("trends", "02", "Trends", "Billing, payments and the four-component split, month by month.", "bi-graph-up-arrow"),
        new("payer", "03", "Payer Analysis", "Payers and payer types: payments, fully-paid and denial rates, balances.", "bi-bar-chart-line"),
        new("service", "04", "Panel & Billing", "Volume and payment by panel, scored by how each panel is billed.", "bi-clipboard2-pulse"),
        new("cpt", "05", "CPT Analysis", "Service mix, modifiers, write-offs and payment per unit by payer.", "bi-upc-scan"),
        new("provider", "06", "Clinic & Provider", "Charges, collections, denials and open AR by clinic or referring provider.", "bi-hospital"),
        new("claimstatus", "07", "Claim Status", "Where claims sit in AR, what is collectible, and how old it is.", "bi-diagram-3"),
        new("denial", "08", "Denial Analysis", "Denials by code, category, payer and panel.", "bi-x-octagon"),
        new("sourcedata", "09", "Source Data", "Every claim behind the figures - filter, reconcile and export CSV.", "bi-database"),
    ];
}
