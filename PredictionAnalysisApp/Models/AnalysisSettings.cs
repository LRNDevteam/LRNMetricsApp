namespace PredictionAnalysis.Models;

public class AnalysisSettings
{
    public string InputFolderPath             { get; set; } = string.Empty;
    public string OutputFolderPath            { get; set; } = string.Empty;
    public string LogOutputFolderPath         { get; set; } = string.Empty;
    public string SheetName                   { get; set; } = string.Empty;
    public ColumnMapping Columns              { get; set; } = new();
    public List<string> ForecastingPIncludeValues { get; set; } = [];
    public string PayStatusDenied             { get; set; } = string.Empty;
    public string PayStatusAdjusted           { get; set; } = string.Empty;
    public string PayStatusNoResponse         { get; set; } = string.Empty;
    public string PayStatusPaid               { get; set; } = string.Empty;
    public int TopDenialCodesPerPayer         { get; set; } = 5;
}

public class ColumnMapping
{
    public string AccessionNumber     { get; set; } = string.Empty;
    public string VisitNumber         { get; set; } = string.Empty;
    public string PayerName           { get; set; } = string.Empty;
    public string PanelName           { get; set; } = string.Empty;
    public string ForecastingP        { get; set; } = string.Empty;
    public string PayStatus           { get; set; } = string.Empty;
    public string DenialCode          { get; set; } = string.Empty;
    public string DenialDescription   { get; set; } = string.Empty;
    public string ExpectedPaymentDate { get; set; } = string.Empty;
    public string FirstBilledDate     { get; set; } = string.Empty;
    public string ModeAllowedAmount   { get; set; } = string.Empty;
    public string ModeInsurancePaid   { get; set; } = string.Empty;
    public string AllowedAmount       { get; set; } = string.Empty;
    public string InsurancePayment    { get; set; } = string.Empty;
}

/// <summary>
/// Loaded from readme.json — drives the Read Me sheet content entirely from JSON.
/// Add, remove or edit entries in readme.json; no code change needed.
/// </summary>
public class ReadMeSettings
{
    public List<ReadMeEntry> Metrics { get; set; } = [];
    public List<ReadMeEntry> Ratios  { get; set; } = [];
}

public class ReadMeEntry
{
    public string Label       { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
}

public class LabConfigSettings
{
    public string LabConfigFolder { get; set; } = string.Empty;
    public List<string> Labs      { get; set; } = [];
}