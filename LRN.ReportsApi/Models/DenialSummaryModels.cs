namespace LRN.ReportsApi.Models;

/// <summary>
/// The two tables on the Denial Summary page. An observation belongs to one row of one of them,
/// keyed by the row's display name (e.g. "Medical Necessity", "Rebill", "Unclassified").
/// </summary>
public static class DenialSummaryTypes
{
    public const string Classification = "Classification";
    public const string ActionCategory = "ActionCategory";

    public static string? Canonical(string? value)
    {
        var token = new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        return token switch
        {
            "CLASSIFICATION" or "DENIALCLASSIFICATION" => Classification,
            "ACTIONCATEGORY" or "ACTION" or "ACTIONTASK" => ActionCategory,
            _ => null
        };
    }
}

public static class DenialSummarySnapshotPeriodTypes
{
    public const string Weekly = "Weekly";
    public const string Monthly = "Monthly";
    public const string OnDemand = "OnDemand";

    public static string? Canonical(string? value)
    {
        var token = new string((value ?? string.Empty).Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        return token switch
        {
            "WEEKLY" => Weekly,
            "MONTHLY" => Monthly,
            "ONDEMAND" or "MANUAL" => OnDemand,
            _ => null
        };
    }
}

/// <summary>Observation, owner and follow-up dates for one Denial Summary row (spec 4a-4d).</summary>
public sealed class DenialSummaryObservation
{
    public string SummaryType { get; set; } = string.Empty;
    public string SummaryKey { get; set; } = string.Empty;

    /// <summary>Sanitized rich text. Only formatting tags, never attributes - see <c>DenialSummaryHtml</c>.</summary>
    public string? ObservationHtml { get; set; }

    /// <summary>Free text on purpose: the owner is often outside the lab's user list (a payer rep, a client contact).</summary>
    public string? ResponsiblePerson { get; set; }

    public DateTime? ObservationDate { get; set; }
    public DateTime? TargetDate { get; set; }
    public DateTime? FollowUpDate { get; set; }
    public DateTime? CompletedDate { get; set; }
    public DateTime CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
    public DateTime? UpdatedOn { get; set; }
    public string? UpdatedBy { get; set; }

    /// <summary>Base64 rowversion. Send it back on save so two editors cannot silently overwrite each other.</summary>
    public string? Version { get; set; }
}

public sealed class DenialSummaryObservationRequest
{
    public string SummaryType { get; set; } = string.Empty;
    public string SummaryKey { get; set; } = string.Empty;
    public string? ObservationHtml { get; set; }
    public string? ResponsiblePerson { get; set; }
    public DateTime? ObservationDate { get; set; }
    public DateTime? TargetDate { get; set; }
    public DateTime? FollowUpDate { get; set; }
    public DateTime? CompletedDate { get; set; }

    /// <summary>Null when creating the row's first observation.</summary>
    public string? Version { get; set; }
}

public sealed class DenialSummaryObservationSaveResult
{
    public bool Saved { get; set; }
    public bool Conflict { get; set; }
    public DenialSummaryObservation? Observation { get; set; }
}

public sealed class DenialSummarySnapshotInfo
{
    public long SnapshotId { get; set; }
    public int LabId { get; set; }
    public string PeriodType { get; set; } = string.Empty;
    public DateTime PeriodStart { get; set; }
    public DateTime PeriodEnd { get; set; }
    public string FileName { get; set; } = string.Empty;
    public long SizeBytes { get; set; }
    public int TotalClaims { get; set; }
    public decimal TotalInsuranceBalance { get; set; }
    public bool IsArchived { get; set; }
    public DateTime? ArchivedOn { get; set; }
    public DateTime CreatedOn { get; set; }
    public string? CreatedBy { get; set; }
}

public sealed class DenialSummarySnapshotFile
{
    public string FileName { get; set; } = string.Empty;
    public byte[] Content { get; set; } = Array.Empty<byte>();
}

/// <summary>Bound from appsettings "DenialSummarySnapshots" (spec 4g-4i).</summary>
public sealed class DenialSummarySnapshotOptions
{
    /// <summary>Turns the automatic weekly/monthly capture off. On-demand snapshots still work.</summary>
    public bool ScheduleEnabled { get; set; } = true;

    /// <summary>How often the scheduler looks for a completed week or month nobody has captured yet.</summary>
    public int CheckIntervalMinutes { get; set; } = 60;

    /// <summary>Active snapshots kept per lab; older ones are archived, never deleted.</summary>
    public int WeeklyRetention { get; set; } = 12;
    public int MonthlyRetention { get; set; } = 12;
    public int OnDemandRetention { get; set; } = 12;

    /// <summary>Windows or IANA id deciding when a week/month has ended. Blank = server local time.</summary>
    public string TimeZoneId { get; set; } = string.Empty;
}
