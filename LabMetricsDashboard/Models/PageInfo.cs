namespace LabMetricsDashboard.Models;

/// <summary>
/// Paging metadata shared by detail view models.
/// </summary>
public sealed record PageInfo(
    int CurrentPage,
    int PageSize,
    int TotalFiltered,
    int TotalAll)
{
    public int TotalPages => PageSize <= 0 ? 1 : (int)Math.Ceiling((double)TotalFiltered / PageSize);
    public bool HasPrev   => CurrentPage > 1;
    public bool HasNext   => CurrentPage < TotalPages;
    public int  FirstItem => TotalFiltered == 0 ? 0 : (CurrentPage - 1) * PageSize + 1;
    public int  LastItem  => Math.Min(CurrentPage * PageSize, TotalFiltered);
}
