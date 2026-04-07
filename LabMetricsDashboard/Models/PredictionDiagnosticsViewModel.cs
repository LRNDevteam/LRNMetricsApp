namespace LabMetricsDashboard.Models;

/// <summary>
/// View model for the Prediction Diagnostics page that shows
/// raw field distributions and filter-step counts from the source file.
/// </summary>
public sealed class PredictionDiagnosticsViewModel
{
    public List<string> AvailableLabs { get; init; } = [];
    public string SelectedLab { get; init; } = string.Empty;

    /// <summary>Full path of the resolved source file.</summary>
    public string SourceFilePath { get; init; } = string.Empty;

    /// <summary>Whether data was loaded from DB or file.</summary>
    public bool UsingDb { get; init; }

    public int TotalRows { get; init; }
    public string WeekStart { get; init; } = string.Empty;

    // ?? Distinct value lists ?????????????????????????????????????????
    public List<DiagnosticDistinctValue> ForecastingPayabilityValues { get; init; } = [];
    public List<string> PayStatusValues { get; init; } = [];
    public List<DiagnosticDateSample> ExpectedPaymentDateSamples { get; init; } = [];

    // ?? Sample records ???????????????????????????????????????????????
    public List<DiagnosticSampleRecord> SampleRecords { get; init; } = [];

    // ?? Filter step counts ???????????????????????????????????????????
    public int AfterForecastFilter { get; init; }
    public int AfterBothFilters { get; init; }
}

/// <summary>A distinct value with its string length (helps spot invisible chars).</summary>
public sealed record DiagnosticDistinctValue(string Value, int Length);

/// <summary>A sample ExpectedPaymentDate value with its parse result.</summary>
public sealed record DiagnosticDateSample(
    string RawValue,
    bool Parsed,
    string ParsedDate,
    bool PassesFilter);

/// <summary>Key fields from one sample record.</summary>
public sealed record DiagnosticSampleRecord(
    string VisitNumber,
    string CPTCode,
    string PayStatus,
    string ForecastingPayability,
    string ExpectedPaymentDate,
    decimal ModeAllowedAmount,
    decimal ModeInsurancePaid,
    decimal MedianAllowedAmount,
    decimal MedianInsurancePaid);
