using System.Text.Json;

namespace LRN.ReportQueue.Shared;

/// <summary>
/// Filter snapshot for a Payer Policy Validation request. Serialized to
/// UserReqReports.FilterDetails by the web app and deserialized by the worker —
/// living in the shared library keeps both sides in lock-step.
/// </summary>
public sealed record PayerPolicyValidationFilters(
    string? PayerName                      = null,
    string? PanelName                      = null,
    string? FinalCoverageStatus            = null,
    string? CPTCode                        = null,
    string? ForecastingPayabilitySubstatus = null,
    string? PredictionStatus               = null,
    string? PayStatus                      = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static PayerPolicyValidationFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new PayerPolicyValidationFilters()
            : JsonSerializer.Deserialize<PayerPolicyValidationFilters>(json, JsonOpts)
              ?? new PayerPolicyValidationFilters();

    /// <summary>Non-empty filters as (Label, Value) — for the filter summary block in the workbook.</summary>
    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        Add("Payer Name", PayerName);
        Add("Panel", PanelName);
        Add("Final Coverage", FinalCoverageStatus);
        Add("CPT Code", CPTCode);
        Add("Forecast Substatus", ForecastingPayabilitySubstatus);
        Add("Prediction Status", PredictionStatus);
        Add("Pay Status", PayStatus);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
    }
}

/// <summary>Filter snapshot for a Prediction Analysis export (matches ExportPredictionExcel's params).</summary>
public sealed record PredictionAnalysisFilters(
    string? PayerName                      = null,
    string? PayerType                      = null,
    string? PanelName                      = null,
    string? FinalCoverageStatus            = null,
    string? Payability                     = null,
    string? CPTCode                        = null,
    string? ForecastingPayability          = null,
    string? PayStatus                      = null,
    string? ForecastingPayabilitySubstatus = null,
    string? PredictionStatus               = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static PredictionAnalysisFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new PredictionAnalysisFilters()
            : JsonSerializer.Deserialize<PredictionAnalysisFilters>(json, JsonOpts)
              ?? new PredictionAnalysisFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        Add("Payer Name", PayerName);
        Add("Payer Type", PayerType);
        Add("Panel Name", PanelName);
        Add("Final Coverage Status", FinalCoverageStatus);
        Add("Payability", Payability);
        Add("CPT Code", CPTCode);
        Add("Forecasting Payability", ForecastingPayability);
        Add("Pay Status", PayStatus);
        Add("Forecasting Payability Substatus", ForecastingPayabilitySubstatus);
        Add("Prediction Status", PredictionStatus);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
    }
}

/// <summary>
/// Filter snapshot for a Collection Report export (matches CollectionSummaryController.ExportExcel's
/// params). Dates travel as strings exactly as the page sends them; parsed with DateOnly.TryParse
/// on the worker — same semantics as the synchronous action.
/// </summary>
public sealed record CollectionReportFilters(
    List<string>? PayerNames    = null,
    List<string>? PanelNames    = null,
    string? FirstBillFrom       = null,
    string? FirstBillTo         = null,
    string? DosFrom             = null,
    string? DosTo               = null,
    string? CheckDateFrom       = null,
    string? CheckDateTo         = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static CollectionReportFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new CollectionReportFilters()
            : JsonSerializer.Deserialize<CollectionReportFilters>(json, JsonOpts)
              ?? new CollectionReportFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        if (PayerNames is { Count: > 0 }) list.Add(("Payer Names", string.Join(", ", PayerNames)));
        if (PanelNames is { Count: > 0 }) list.Add(("Panel Names", string.Join(", ", PanelNames)));
        Add("First Bill From", FirstBillFrom);
        Add("First Bill To", FirstBillTo);
        Add("Date of Service From", DosFrom);
        Add("Date of Service To", DosTo);
        Add("Check Date From", CheckDateFrom);
        Add("Check Date To", CheckDateTo);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
    }
}

/// <summary>
/// Filter snapshot for a Claim Level Details export — mirrors DashboardController.ClaimLevel's
/// filter parameters exactly (same WHERE building via SqlClaimLineRepository).
/// </summary>
public sealed record ClaimLevelDetailsFilters(
    string?       PayerName                = null,
    List<string>? PayerTypes               = null,
    List<string>? ClaimStatuses            = null,
    List<string>? ClinicNames              = null,
    string?       DenialCode               = null,
    bool          DenialCodeExcludeBlank   = false,
    List<string>? PayerNames               = null,
    bool          PayerExcludeBlank        = false,
    List<string>? PanelNames               = null,
    bool          PanelExcludeBlank        = false,
    List<string>? AgingBuckets             = null,
    string?       FirstBillFrom            = null,
    string?       FirstBillTo              = null,
    bool          FirstBillNull            = false,
    bool          FirstBillExcludeBlank    = false,
    string?       ChargeEnteredFrom        = null,
    string?       ChargeEnteredTo          = null,
    bool          ChargeEnteredNull        = false,
    bool          ChargeEnteredExcludeBlank = false,
    string?       DosFrom                  = null,
    string?       DosTo                    = null,
    bool          DosNull                  = false)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static ClaimLevelDetailsFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new ClaimLevelDetailsFilters()
            : JsonSerializer.Deserialize<ClaimLevelDetailsFilters>(json, JsonOpts)
              ?? new ClaimLevelDetailsFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        Add("Payer Name (search)", PayerName);
        AddList("Payer Names", PayerNames);
        AddList("Panel Names", PanelNames);
        AddList("Payer Types", PayerTypes);
        AddList("Claim Statuses", ClaimStatuses);
        AddList("Clinics", ClinicNames);
        AddList("Aging Buckets", AgingBuckets);
        Add("Denial Code", DenialCode);
        Add("First Billed From", FirstBillFrom);
        Add("First Billed To", FirstBillTo);
        Add("Charge Entered From", ChargeEnteredFrom);
        Add("Charge Entered To", ChargeEnteredTo);
        Add("Date of Service From", DosFrom);
        Add("Date of Service To", DosTo);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
        void AddList(string label, List<string>? values)
        {
            if (values is { Count: > 0 }) list.Add((label, string.Join(", ", values)));
        }
    }
}

/// <summary>
/// Filter snapshot for a Line Level Details export — mirrors DashboardController.LineLevel's
/// filter parameters exactly.
/// </summary>
public sealed record LineLevelDetailsFilters(
    string?       PayerName     = null,
    List<string>? PayerTypes    = null,
    List<string>? ClaimStatuses = null,
    List<string>? PayStatuses   = null,
    List<string>? CPTCodes      = null,
    List<string>? ClinicNames   = null,
    string?       DenialCode    = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static LineLevelDetailsFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new LineLevelDetailsFilters()
            : JsonSerializer.Deserialize<LineLevelDetailsFilters>(json, JsonOpts)
              ?? new LineLevelDetailsFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        Add("Payer Name (search)", PayerName);
        AddList("Payer Types", PayerTypes);
        AddList("Claim Statuses", ClaimStatuses);
        AddList("Pay Statuses", PayStatuses);
        AddList("CPT Codes", CPTCodes);
        AddList("Clinics", ClinicNames);
        Add("Denial Code", DenialCode);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
        void AddList(string label, List<string>? values)
        {
            if (values is { Count: > 0 }) list.Add((label, string.Join(", ", values)));
        }
    }
}

/// <summary>
/// Filter snapshot for Clinic Summary / Sales Rep Summary exports — matches
/// DashboardController.ExportClinicSummaryExcel / ExportSalesRepSummaryExcel's
/// parameters exactly (both actions take the same filter set).
/// Dates travel as strings exactly as the pages send them.
/// </summary>
public sealed record ClinicSalesRepSummaryFilters(
    List<string>? ClinicNames   = null,
    List<string>? SalesRepNames = null,
    List<string>? PayerNames    = null,
    List<string>? PanelNames    = null,
    string?       DosFrom       = null,
    string?       DosTo         = null,
    string?       FirstBillFrom = null,
    string?       FirstBillTo   = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static ClinicSalesRepSummaryFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new ClinicSalesRepSummaryFilters()
            : JsonSerializer.Deserialize<ClinicSalesRepSummaryFilters>(json, JsonOpts)
              ?? new ClinicSalesRepSummaryFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        AddList("Clinics", ClinicNames);
        AddList("Sales Reps", SalesRepNames);
        AddList("Payers", PayerNames);
        AddList("Panels", PanelNames);
        Add("Date of Service From", DosFrom);
        Add("Date of Service To", DosTo);
        Add("First Bill From", FirstBillFrom);
        Add("First Bill To", FirstBillTo);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
        void AddList(string label, List<string>? values)
        {
            if (values is { Count: > 0 }) list.Add((label, string.Join(", ", values)));
        }
    }
}

/// <summary>
/// Filter snapshot for a Revenue Dashboard export — matches
/// DashboardController.ExportDashboardExcel / Index's filter parameters exactly.
/// Dates travel as strings exactly as the page sends them.
/// </summary>
public sealed record RevenueDashboardFilters(
    List<string>? PayerNames       = null,
    string?       PayerType        = null,
    List<string>? PanelNames       = null,
    string?       ClinicName       = null,
    string?       ReferringProvider = null,
    string?       DosFrom          = null,
    string?       DosTo            = null,
    string?       FirstBillFrom    = null,
    string?       FirstBillTo      = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static RevenueDashboardFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new RevenueDashboardFilters()
            : JsonSerializer.Deserialize<RevenueDashboardFilters>(json, JsonOpts)
              ?? new RevenueDashboardFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        if (PayerNames is { Count: > 0 }) list.Add(("Payer Names", string.Join(", ", PayerNames)));
        Add("Payer Type", PayerType);
        if (PanelNames is { Count: > 0 }) list.Add(("Panel Names", string.Join(", ", PanelNames)));
        Add("Clinic", ClinicName);
        Add("Referring Provider", ReferringProvider);
        Add("Date of Service From", DosFrom);
        Add("Date of Service To", DosTo);
        Add("First Bill From", FirstBillFrom);
        Add("First Bill To", FirstBillTo);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
    }
}

/// <summary>
/// Filter snapshot for a Production Report / Production Summary Report export —
/// matches ExportProductionReportExcel / ExportNorthWestProductionReportExcel's params.
/// Dates travel as strings exactly as the page sends them (DateOnly.TryParse on the worker).
/// </summary>
public sealed record ProductionReportFilters(
    List<string>? PayerNames  = null,
    List<string>? PanelNames  = null,
    string? DosFrom           = null,
    string? DosTo             = null,
    string? FirstBillFrom     = null,
    string? FirstBillTo       = null,
    string? FirstBilledFrom   = null,
    string? FirstBilledTo     = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static ProductionReportFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new ProductionReportFilters()
            : JsonSerializer.Deserialize<ProductionReportFilters>(json, JsonOpts)
              ?? new ProductionReportFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        if (PayerNames is { Count: > 0 }) list.Add(("Payer Names", string.Join(", ", PayerNames)));
        if (PanelNames is { Count: > 0 }) list.Add(("Panel Names", string.Join(", ", PanelNames)));
        Add("Date of Service From", DosFrom);
        Add("Date of Service To", DosTo);
        Add("First Bill From", FirstBillFrom);
        Add("First Bill To", FirstBillTo);
        Add("First Billed From", FirstBilledFrom);
        Add("First Billed To", FirstBilledTo);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
    }
}

/// <summary>
/// Filter snapshot for an Executive Summary export — matches ExecutiveSummaryController.Index's
/// params (year/month range, DOS/billed windows, dimension multi-selects).
/// </summary>
public sealed record ExecutiveSummaryFilters(
    int?          YearFrom   = null,
    int?          YearTo     = null,
    int?          MonthFrom  = null,
    int?          MonthTo    = null,
    string?       DosFrom    = null,
    string?       DosTo      = null,
    string?       BilledFrom = null,
    string?       BilledTo   = null,
    List<string>? Panels     = null,
    List<string>? Clinics    = null,
    List<string>? Providers  = null,
    List<string>? Reps       = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static ExecutiveSummaryFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new ExecutiveSummaryFilters()
            : JsonSerializer.Deserialize<ExecutiveSummaryFilters>(json, JsonOpts)
              ?? new ExecutiveSummaryFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        if (YearFrom is not null)  list.Add(("Year From", YearFrom.ToString()));
        if (YearTo is not null)    list.Add(("Year To", YearTo.ToString()));
        if (MonthFrom is not null) list.Add(("Month From", MonthFrom.ToString()));
        if (MonthTo is not null)   list.Add(("Month To", MonthTo.ToString()));
        Add("DOS From", DosFrom);
        Add("DOS To", DosTo);
        Add("Billed From", BilledFrom);
        Add("Billed To", BilledTo);
        AddList("Panels", Panels);
        AddList("Clinics", Clinics);
        AddList("Providers", Providers);
        AddList("Reps", Reps);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
        void AddList(string label, List<string>? values)
        {
            if (values is { Count: > 0 }) list.Add((label, string.Join(", ", values)));
        }
    }
}

/// <summary>Filter snapshot for a Forecasting Summary export (matches ExportForecastingExcel's params).</summary>
public sealed record ForecastingSummaryFilters(
    string? PayerName = null,
    string? PayerType = null,
    string? PanelName = null,
    string? CPTCode   = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static ForecastingSummaryFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new ForecastingSummaryFilters()
            : JsonSerializer.Deserialize<ForecastingSummaryFilters>(json, JsonOpts)
              ?? new ForecastingSummaryFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        Add("Payer Name", PayerName);
        Add("Payer Type", PayerType);
        Add("Panel", PanelName);
        Add("CPT Code", CPTCode);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
    }
}

/// <summary>
/// Filter snapshot for a Denial Dashboard export — mirrors
/// DenialDashboardController.ExportToExcel's DenialDashboardFilters. The multi-choice
/// filters travel pipe-delimited exactly as the page posts them ("(All)" = no filter),
/// and dates as strings, so the worker rebuilds the page's own filter object verbatim.
/// </summary>
public sealed record DenialDashboardReportFilters(
    int?    LabId               = null,
    string? DenialCode          = null,
    string? Status              = null,
    string? Priority            = null,
    string? ActionCategory      = null,
    string? Deadline            = null,
    string? Classification      = null,
    string? SalesRepname        = null,
    string? ClinicName          = null,
    string? ReferringProvider   = null,
    string? PayerName           = null,
    string? PayerType           = null,
    string? PanelName           = null,
    string? FirstBilledDateFrom = null,
    string? FirstBilledDateTo   = null,
    string? DateOfServiceFrom   = null,
    string? DateOfServiceTo     = null,
    string? DenialDateFrom      = null,
    string? DenialDateTo        = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static DenialDashboardReportFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new DenialDashboardReportFilters()
            : JsonSerializer.Deserialize<DenialDashboardReportFilters>(json, JsonOpts)
              ?? new DenialDashboardReportFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        AddChoice("Status", Status);
        AddChoice("Priority", Priority);
        AddChoice("Action Category", ActionCategory);
        AddChoice("Deadline", Deadline);
        AddChoice("Classification", Classification);
        AddChoice("Denial Code", DenialCode);
        AddChoice("Sales Rep", SalesRepname);
        AddChoice("Clinic", ClinicName);
        AddChoice("Referring Provider", ReferringProvider);
        AddChoice("Payer Name", PayerName);
        AddChoice("Payer Type", PayerType);
        AddChoice("Panel Name", PanelName);
        Add("First Billed From", FirstBilledDateFrom);
        Add("First Billed To", FirstBilledDateTo);
        Add("Date of Service From", DateOfServiceFrom);
        Add("Date of Service To", DateOfServiceTo);
        Add("Denial Date From", DenialDateFrom);
        Add("Denial Date To", DenialDateTo);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
        void AddChoice(string label, string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            // "(All)" is the page's own "no filter" sentinel — never a real selection.
            var parts = value
                .Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Where(x => !x.Equals("(All)", StringComparison.OrdinalIgnoreCase))
                .ToList();
            if (parts.Count > 0) list.Add((label, string.Join(", ", parts)));
        }
    }
}

/// <summary>
/// Filter snapshot for a LIS Summary / LIMS Master export — mirrors
/// LisSummaryController.ExportToExcel's parameters exactly. The multi-select
/// filters (Panel/Clinic/RefPhy/SalesRep/Collector) travel pipe-delimited, the
/// same shape the page's hidden inputs post, so the worker reuses the page's
/// WHERE building untouched.
/// </summary>
public sealed record LisSummaryReportFilters(
    int?    LabId     = null,
    string? DateType  = null,
    string? DateFrom  = null,
    string? DateTo    = null,
    string? Panel     = null,
    string? Clinic    = null,
    string? RefPhy    = null,
    string? SalesRep  = null,
    string? Collector = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static LisSummaryReportFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new LisSummaryReportFilters()
            : JsonSerializer.Deserialize<LisSummaryReportFilters>(json, JsonOpts)
              ?? new LisSummaryReportFilters();

    /// <summary>"Collected" unless the page asked for one of the other LIMS date columns.</summary>
    public string EffectiveDateType =>
        DateType is not null
        && (DateType.Equals("Received", StringComparison.OrdinalIgnoreCase)
            || DateType.Equals("Resulted", StringComparison.OrdinalIgnoreCase))
            ? DateType
            : "Collected";

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>
        {
            ("Date Type", EffectiveDateType),
        };
        Add("Date From", DateFrom);
        Add("Date To", DateTo);
        AddMulti("Panel", Panel);
        AddMulti("Clinic", Clinic);
        AddMulti("Ref Phy", RefPhy);
        AddMulti("Sales Rep", SalesRep);
        AddMulti("Collector", Collector);
        return list;

        void Add(string label, string? value)
        {
            if (!string.IsNullOrWhiteSpace(value)) list.Add((label, value));
        }
        void AddMulti(string label, string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) return;
            var parts = value.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (parts.Length > 0) list.Add((label, string.Join(", ", parts)));
        }
    }
}

/// <summary>
/// Filter snapshot for a Coding Summary Excel export. The page currently exports
/// the full lab dataset (no server-side year/week/panel filter); this contract
/// exists so queue validation stays consistent with other report types.
/// </summary>
public sealed record CodingSummaryFilters(
    string? Note = null)
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    public string ToJson() => JsonSerializer.Serialize(this, JsonOpts);

    public static CodingSummaryFilters FromJson(string? json) =>
        string.IsNullOrWhiteSpace(json)
            ? new CodingSummaryFilters()
            : JsonSerializer.Deserialize<CodingSummaryFilters>(json, JsonOpts)
              ?? new CodingSummaryFilters();

    public List<(string Label, string? Value)> ToActiveFilterList()
    {
        var list = new List<(string, string?)>();
        if (!string.IsNullOrWhiteSpace(Note)) list.Add(("Note", Note));
        return list;
    }
}
