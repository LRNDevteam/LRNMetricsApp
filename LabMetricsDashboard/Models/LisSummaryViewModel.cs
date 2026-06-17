namespace LabMetricsDashboard.Models;

public sealed class LisSummaryViewModel
{
    public List<LabOption> LabOptions { get; init; } = [];
    public int? SelectedLabId { get; init; }
    public string? SelectedLab { get; init; }
    public string? FilterCollectedFrom { get; init; }
    public string? FilterCollectedTo { get; init; }
    public string? LogicSheetName { get; init; }
    public List<string> Months { get; init; } = [];
    public List<int> Years { get; init; } = [];
    public List<LisSummaryRow> Rows { get; init; } = [];
    public Dictionary<string, int> GrandTotalByMonth { get; init; } = [];
    public Dictionary<int, int> GrandTotalByYear { get; init; } = [];
    public int GrandTotal { get; init; }
    public string? ErrorMessage { get; init; }
    public bool HasFilters => !string.IsNullOrWhiteSpace(FilterCollectedFrom) || !string.IsNullOrWhiteSpace(FilterCollectedTo);
}

public sealed class LisSummaryRow
{
    public string Code { get; init; } = string.Empty;
    public string Description { get; init; } = string.Empty;
    public string Logic { get; init; } = string.Empty;
    public int Level { get; init; }
    public Dictionary<string, int> ByMonth { get; init; } = [];
    public Dictionary<int, int> ByYear { get; init; } = [];
    public int Total { get; init; }
    public bool IsSection => Code.Equals("A", StringComparison.OrdinalIgnoreCase) || Code.Equals("B", StringComparison.OrdinalIgnoreCase);
    public bool IsBullet => Code is "•" or "◦";
}

public sealed record LisSummaryResult(
    string LogicSheetName,
    string SourceFileName,
    List<string> Months,
    List<int> Years,
    List<LisSummaryRow> Rows,
    Dictionary<string, int> GrandTotalByMonth,
    Dictionary<int, int> GrandTotalByYear,
    int GrandTotal,
    LisSummaryKpiCards KpiCards);

public sealed record LisSummaryKpiCards(
    int TotalSamples,
    int BilledCount,
    int UnbilledCount,
    int SelfPayCount);

public sealed record LisSummaryFilterOptions(
    List<string> Panels,
    List<string> Clinics,
    List<string> RefPhysicians,
    List<string> SalesReps);

public sealed record LisLineDataRow(
    string OrderId,
    string SampleId,
    string PaymentMethod,
    string Barcode,
    string Specimen,
    string Collector,
    string OrderStatus,
    string BillingStatus,
    string SampleStatus,
    DateTime? RequestSubmittedDate,
    DateTime? RequestCollectDate,
    DateTime? ReqReceivedDate,
    DateTime? ReqReportedDate,
    DateTime? ValidatedDate,
    string ResultedStatus,
    string ClientStatus,
    string SubStatus,
    string TimetoResult,
    string TurnaroundTime,
    string PerformingLaboratory,
    string Results,
    string PatientName,
    string PatientFirstName,
    string PatientLastName,
    DateTime? PatientDateofBirth,
    string VisitNumber,
    string AMDDOE,
    string AMDLBD,
    DateTime? BilledDate,
    string TimetoBill,
    string ClaimStatus,
    string BilledorNot,
    string ClinicName,
    string Provider,
    string SalesRepName,
    string PrimaryInsurance,
    string PrimaryInsuranceID,
    string ICD10Codes,
    string Tests,
    string PanelCategory,
    string InsuranceCategory,
    string Client,
    string RequisitionType,
    DateTime? DateOfService,
    string Medications,
    string FacilityState,
    string RelationshipToInsured,
    string FacilityCity,
    string FacilityZipcode,
    string FacilityAddress,
    string PolicyId,
    string GroupId,
    string ReferenceId,
    DateTime? PolicyHolderDOB,
    string Address,
    string Email,
    string City,
    string Gender,
    string State,
    string TransferTo,
    string PatientEthnicity,
    string ZipCode,
    string Race,
    string LabCode,
    string NoInsuranceInfo);

public sealed record LisLineDataResult(
    List<LisLineDataRow> Rows,
    int TotalCount,
    int PageNumber,
    int PageSize);
    
public sealed class LisSummaryFilters
{
    private static readonly HashSet<string> AllowedDateTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "Collected",
        "Received",
        "Resulted"
    };

    private static readonly HashSet<string> AllowedDateRanges = new(StringComparer.OrdinalIgnoreCase)
    {
        "custom",
        "this-week",
        "last-week",
        "this-month",
        "last-month"
    };

    public int? LabId { get; set; }
    public DateOnly? CollectedFrom { get; set; }
    public DateOnly? CollectedTo { get; set; }
    public string DateType { get; set; } = "Collected";
    public string DateRange { get; set; } = "custom";
    public DateOnly? DateFrom { get; set; }
    public DateOnly? DateTo { get; set; }
    public string? Panel { get; set; }
    public string? Clinic { get; set; }
    public string? RefPhy { get; set; }
    public string? SalesRep { get; set; }
    public string? ActiveTab { get; set; } = "summary";
    public int PageNumber { get; set; } = 1;
    public int PageSize { get; set; } = 100;

    public string EffectiveDateType
        => AllowedDateTypes.Contains(DateType ?? string.Empty) ? DateType! : "Collected";

    public string EffectiveDateRange
        => AllowedDateRanges.Contains(DateRange ?? string.Empty) ? DateRange! : "custom";

    public DateOnly? EffectiveDateFrom => DateFrom ?? CollectedFrom;
    public DateOnly? EffectiveDateTo => DateTo ?? CollectedTo;
    public string EffectiveActiveTab => ActiveTab?.Equals("line", StringComparison.OrdinalIgnoreCase) == true ? "line" : "summary";

    public void Normalize()
    {
        DateType = EffectiveDateType;
        DateFrom ??= CollectedFrom;
        DateTo ??= CollectedTo;
        DateRange = EffectiveDateRange;
        ApplyDateRangePreset();
        ActiveTab = EffectiveActiveTab;
        PageNumber = Math.Max(1, PageNumber);
        PageSize = PageSize is < 10 or > 500 ? 100 : PageSize;
    }

    private void ApplyDateRangePreset()
    {
        var today = DateOnly.FromDateTime(DateTime.Today);
        var startOfThisWeek = today.AddDays(-(((int)today.DayOfWeek + 6) % 7));

        switch (DateRange)
        {
            case "this-week":
                DateFrom = startOfThisWeek;
                DateTo = today;
                break;
            case "last-week":
                DateFrom = startOfThisWeek.AddDays(-7);
                DateTo = startOfThisWeek.AddDays(-1);
                break;
            case "this-month":
                DateFrom = new DateOnly(today.Year, today.Month, 1);
                DateTo = today;
                break;
            case "last-month":
                var firstOfThisMonth = new DateOnly(today.Year, today.Month, 1);
                var firstOfLastMonth = firstOfThisMonth.AddMonths(-1);
                DateFrom = firstOfLastMonth;
                DateTo = firstOfThisMonth.AddDays(-1);
                break;
            default:
                if (DateFrom.HasValue && !DateTo.HasValue)
                {
                    DateTo = today;
                }
                break;
        }
    }
}
