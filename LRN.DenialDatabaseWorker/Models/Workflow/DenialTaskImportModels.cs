namespace DenialDatabaseProcessorWorker.Models.Workflow;

public sealed class DenialTaskImportRequest
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
    public string RunId { get; set; } = string.Empty;
    public List<DenialTaskImportRow> Tasks { get; set; } = new();
}

public sealed class DenialTaskImportRow
{
    public string UniqueTrackId { get; set; } = string.Empty;
    public string ClaimUid { get; set; } = string.Empty;
    public string ClaimId { get; set; } = string.Empty;
    public string PatientId { get; set; } = string.Empty;
    public string CptCode { get; set; } = string.Empty;
    public string DenialCode { get; set; } = string.Empty;
    public string DenialDescription { get; set; } = string.Empty;
    public string DenialClassification { get; set; } = string.Empty;
    public string ActionCode { get; set; } = string.Empty;
    public string RecommendedAction { get; set; } = string.Empty;
    public string ActionCategory { get; set; } = string.Empty;
    public string Task { get; set; } = string.Empty;
    public string Priority { get; set; } = string.Empty;
    public decimal InsuranceBalance { get; set; }
    public int? SlaDays { get; set; }
    public DateTime? DateOpened { get; set; }
    public DateTime? DueDate { get; set; }
    public DateTime? DateCompleted { get; set; }
    public string SalesRepname { get; set; } = string.Empty;
    public string ClinicName { get; set; } = string.Empty;
    public string ReferringProvider { get; set; } = string.Empty;
    public string Source { get; set; } = string.Empty;
    public string PatName { get; set; } = string.Empty;
    public string SubscriberId { get; set; } = string.Empty;
    public string PayerName { get; set; } = string.Empty;
    public string PayerNameNormalized { get; set; } = string.Empty;
    public int? PayerCode { get; set; }
    public string PayerType { get; set; } = string.Empty;
    public DateTime? FirstBilledDate { get; set; }
    public DateTime? ChargeEnteredDate { get; set; }
    public string BillingProvider { get; set; } = string.Empty;
    public string PanelName { get; set; } = string.Empty;
    public DateTime? DateOfService { get; set; }
    public string IcdCodes { get; set; } = string.Empty;
    public string CoverageStatus { get; set; } = string.Empty;
    public string IcdComplianceStatus { get; set; } = string.Empty;
    public string DenialValidity { get; set; } = string.Empty;
}

public sealed class DenialWorkflowImportResult
{
    public int Imported { get; set; }
    public int Created { get; set; }
    public int Updated { get; set; }
    public int MovedToVerification { get; set; }
    public int MovedToHistory { get; set; }
    public int ReopenedToVerification { get; set; }
}
