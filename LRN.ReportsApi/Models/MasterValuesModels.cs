namespace LRN.ReportsApi.Models;

public sealed class InsurancePayerMasterDto
{
    public int LabInsuranceMasterId { get; set; }
    public string? PayerCode { get; set; }
    public string PayerNameRaw { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public int? GlobalPayerID { get; set; }
    public string? PayerGroupCode { get; set; }
    public string? PayerCommonCode { get; set; }
    public string? Parent { get; set; }
    public string? PlanType { get; set; }
    public string? MCOType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? BenefitAdminCode { get; set; }
    public string? BenefitAdministrator { get; set; }
    public string? Remarks { get; set; }
    public string? LabName { get; set; }
    public int? LabId { get; set; }
    public string? LabState { get; set; }
    public string? LabStateCode { get; set; }
}

public sealed class PayerPolicyInsuranceMasterDto
{
    public int PayerPolicyInsuranceMasterId { get; set; }
    public string? PayerCode { get; set; }
    public string PayerName { get; set; } = string.Empty;
    public string? PayerNameNormalized { get; set; }
    public int? GlobalPayerID { get; set; }
    public string? PayerGroupCode { get; set; }
    public string? PayerCommonCode { get; set; }
    public string? PlanType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? BenefitAdminCode { get; set; }
    public string? BenefitAdministrator { get; set; }
    public string? Remarks { get; set; }
    public string? IsMCO { get; set; }
}

public sealed class InsurancePayerMasterQuery
{
    public string? Search { get; set; }
    public int? LabId { get; set; }
    public string? PayerCode { get; set; }
    public string? PayerName { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? IsActive { get; set; }
    public string? SortColumn { get; set; }
    public string? SortDirection { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public sealed class PayerPolicyInsuranceMasterQuery
{
    public string? Search { get; set; }
    public string? PayerCode { get; set; }
    public string? PayerName { get; set; }
    public int? GlobalPayerId { get; set; }
    public string? PlanType { get; set; }
    public string? PayerState { get; set; }
    public string? IsActive { get; set; }
    public string? IsMCO { get; set; }
    public string? SortColumn { get; set; }
    public string? SortDirection { get; set; }
    public int Page { get; set; } = 1;
    public int PageSize { get; set; } = 25;
}

public sealed class ImportResultDto
{
    public int TotalRows { get; set; }
    public int InsertedRows { get; set; }
    public int UpdatedRows { get; set; }
    public int SkippedRows { get; set; }
    public int ErrorRows { get; set; }
    public List<string> Warnings { get; set; } = new();
    public List<string> Errors { get; set; } = new();
}

public sealed class MasterValueStatusRequest
{
    public string? IsActive { get; set; }
}

public sealed class MasterValueImportRequest
{
    public IFormFile? File { get; set; }
}

public sealed class MasterValueLabOption
{
    public int LabId { get; set; }
    public string LabName { get; set; } = string.Empty;
}
