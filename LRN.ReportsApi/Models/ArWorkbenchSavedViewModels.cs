namespace LRN.ReportsApi.Models;

/// <summary>A user's named filter set for one screen (dbo.ARWB_SavedView).</summary>
public sealed class ArWorkbenchSavedView
{
    public int SavedViewId { get; set; }
    public string ViewKey { get; set; } = string.Empty;
    public string ViewName { get; set; } = string.Empty;
    /// <summary>The screen's own filter state, as JSON. The API stores it as given; the screen reads it back.</summary>
    public string? FiltersJson { get; set; }
    public string? HiddenColumnsJson { get; set; }
    public bool IsDefault { get; set; }
    public DateTime CreatedOn { get; set; }
    public DateTime? UpdatedOn { get; set; }
}

/// <summary>Save a view: a name already used on that screen is overwritten.</summary>
public sealed class ArWorkbenchSavedViewRequest
{
    public string? ViewKey { get; set; }
    public string? ViewName { get; set; }
    public string? FiltersJson { get; set; }
    public string? HiddenColumnsJson { get; set; }
    public bool IsDefault { get; set; }
}

/// <summary>Rename a view and/or make it (or stop it being) the screen's default.</summary>
public sealed class ArWorkbenchSavedViewUpdate
{
    public string? ViewName { get; set; }
    public bool? IsDefault { get; set; }
}
