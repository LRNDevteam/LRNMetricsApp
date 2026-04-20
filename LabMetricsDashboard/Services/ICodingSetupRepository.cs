using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>Repository for the Coding Setup (CodingSetupMasterList) CRUD operations.</summary>
public interface ICodingSetupRepository
{
    /// <summary>Paged, searchable, sortable list filtered by lab.</summary>
    Task<(List<PanelPathogenCptRecord> Records, int TotalCount)> GetPagedAsync(
        string labName, string? search, string sortColumn, string sortDirection,
        string activeFilter, int page, int pageSize, CancellationToken ct = default);

    Task<PanelPathogenCptRecord?> GetByIdAsync(string labName, int id, CancellationToken ct = default);

    /// <summary>Check for duplicate combination before insert/update.</summary>
    Task<bool> ExistsDuplicateAsync(string labName, string panelName, string? testName,
        string pathogenName, string cptCode, int? excludeId = null, CancellationToken ct = default);

    Task<int> CreateAsync(CodingSetupFormModel model, string? userName, CancellationToken ct = default);
    Task UpdateAsync(CodingSetupFormModel model, string? userName, CancellationToken ct = default);

    /// <summary>Soft-delete (set IsActive = 0).</summary>
    Task DeactivateAsync(string labName, int id, string? userName, CancellationToken ct = default);

    /// <summary>Clone all combinations from one panel to a new panel name within a lab.</summary>
    Task<int> ClonePanelAsync(string labName, string sourcePanelName, string newPanelName,
        string? userName, CancellationToken ct = default);

    /// <summary>All distinct panel names for a lab (for dropdowns / clone source).</summary>
    Task<List<string>> GetDistinctPanelNamesAsync(string labName, CancellationToken ct = default);

    /// <summary>All distinct dropdown values for a lab's Create / Edit forms.</summary>
    Task<CodingSetupDropdownLookups> GetDropdownLookupsAsync(string labName, CancellationToken ct = default);

    /// <summary>All records for a lab (for export).</summary>
    Task<List<PanelPathogenCptRecord>> GetAllAsync(string labName, string? search,
        string activeFilter, CancellationToken ct = default);

    /// <summary>Bulk import records from CSV.</summary>
    Task<int> BulkImportAsync(string labName, List<CodingSetupFormModel> records,
        string? userName, CancellationToken ct = default);

    /// <summary>Get all active records for a specific panel within a lab.</summary>
    Task<List<PanelPathogenCptRecord>> GetByPanelNameAsync(string labName, string panelName, CancellationToken ct = default);

    /// <summary>Get tests, pathogens, and CPT codes for a panel from the master PanelPathogenCPTlist table.</summary>
    Task<List<PanelPathogenCptRecord>> GetMasterPanelDetailsAsync(string panelName, CancellationToken ct = default);

    /// <summary>Get change history for a record.</summary>
    Task<List<CodingSetupAuditEntry>> GetAuditHistoryAsync(string labName, int recordId, CancellationToken ct = default);
}
