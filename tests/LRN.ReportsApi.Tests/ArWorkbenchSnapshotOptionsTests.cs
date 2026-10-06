using LRN.ReportsApi.Services.ArWorkbench;
using Xunit;

namespace LRN.ReportsApi.Tests;

public class ArWorkbenchSnapshotOptionsTests
{
    private static readonly ArWorkbenchSnapshotOptions Eastern = new() { RunAtHour = 1, TimeZoneId = "Eastern Standard Time" };

    [Fact]
    public void Before_the_run_hour_nothing_is_due()
        // 05:30 UTC on Oct 6 = 01:30 EDT -> due; 04:30 UTC = 00:30 EDT -> not yet.
        => Assert.Null(Eastern.DueDate(new DateTime(2026, 10, 6, 4, 30, 0, DateTimeKind.Utc)));

    [Fact]
    public void After_the_run_hour_today_is_due_in_the_lab_time_zone()
        => Assert.Equal(new DateTime(2026, 10, 6), Eastern.DueDate(new DateTime(2026, 10, 6, 5, 30, 0, DateTimeKind.Utc)));

    [Fact]
    public void Late_evening_utc_is_still_the_local_day()
        // 02:00 UTC Oct 7 = 22:00 EDT Oct 6: Oct 6's snapshot, not Oct 7's.
        => Assert.Equal(new DateTime(2026, 10, 6), Eastern.DueDate(new DateTime(2026, 10, 7, 2, 0, 0, DateTimeKind.Utc)));

    [Fact]
    public void Unknown_time_zone_falls_back_to_server_time()
        => Assert.NotNull(new ArWorkbenchSnapshotOptions { RunAtHour = 0, TimeZoneId = "Nowhere/Nope" }.DueDate(DateTime.UtcNow));
}
