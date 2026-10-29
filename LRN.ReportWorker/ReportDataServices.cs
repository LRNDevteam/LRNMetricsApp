using LRN.ReportWorker.Generators;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace LRN.ReportWorker;

/// <summary>
/// The dashboard data layer the report generators run on: LabSettings from the per-lab JSONs and the
/// same repositories / view-model builders the LRN Metrics pages use. Shared by this worker and
/// LRN.SnapshotGenerator, so a queued Excel export and a weekly snapshot of the same page can never be
/// built from different code.
/// </summary>
public static class ReportDataServices
{
    public static IServiceCollection AddReportDataServices(this IServiceCollection services, IConfiguration configuration)
    {
        // ── Web services reused for Prediction / Forecasting generation ──
        // Same LabSettings the dashboard builds, from the same per-lab JSONs.
        services.AddMemoryCache();
        services.AddSingleton(sp =>
        {
            var opts = configuration.GetSection("ReportWorker").Get<ReportWorkerOptions>()
                       ?? new ReportWorkerOptions();
            var logger = sp.GetRequiredService<ILoggerFactory>()
                           .CreateLogger("LabSettingsFactory");
            return LabSettingsFactory.Build(opts.LabConfigFolder, opts.Labs, logger);
        });
        services.AddSingleton<LabMetricsDashboard.Services.LabCsvFileResolver>();
        services.AddSingleton<LabMetricsDashboard.Services.PredictionReportParserService>();
        services.AddSingleton<LabMetricsDashboard.Services.IPredictionDbRepository,
            LabMetricsDashboard.Services.SqlPredictionDbRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.PredictionInsightLoader>();
        services.AddSingleton<LabMetricsDashboard.Services.DenialDescriptionMasterLookup>();
        services.AddTransient<LabMetricsDashboard.Controllers.PredictionController>();
        services.AddSingleton<LabMetricsDashboard.Services.ICollectionSummaryRepository,
            LabMetricsDashboard.Services.SqlCollectionSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IAnalysisRangeService,
            LabMetricsDashboard.Services.AnalysisRangeService>();
        services.AddTransient<LabMetricsDashboard.Controllers.CollectionSummaryController>();
        services.AddSingleton<LabMetricsDashboard.Services.SqlClaimLineRepository>();
        services.AddSingleton<LRN.ProductionReports.Services.IProductionReportRepository,
            LRN.ProductionReports.Services.SqlProductionReportRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.INorthWestProductionSummaryRepository,
            LabMetricsDashboard.Services.SqlNorthWestProductionSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IAugustusProductionSummaryRepository,
            LabMetricsDashboard.Services.SqlAugustusProductionSummaryRepository>();
        // Per-lab generic Production Summary repositories - same map the web app uses.
        // Without this the queued Production Report Excel has no Panel Breakdown sheet
        // for any lab other than Augustus / NorthWest.
        services.AddSingleton<IReadOnlyDictionary<string, LabMetricsDashboard.Services.ILabProductionSummaryRepository>>(sp =>
            LabMetricsDashboard.Services.LabProductionSummaryRepositoryMap.Create(
                sp.GetRequiredService<ILogger<LabMetricsDashboard.Services.SqlLabProductionSummaryRepository>>()));
        services.AddSingleton<LabMetricsDashboard.Services.SqlPhiExecutiveSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IDashboardRepository,
            LabMetricsDashboard.Services.SqlDashboardRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IClinicSummaryRepository,
            LabMetricsDashboard.Services.SqlClinicSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.ISalesRepSummaryRepository,
            LabMetricsDashboard.Services.SqlSalesRepSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.ICodingValidationRepository,
            LabMetricsDashboard.Services.SqlCodingValidationRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.ILisSummaryRepository,
            LabMetricsDashboard.Services.SqlLisSummaryRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.INotesRepository,
            LabMetricsDashboard.Services.SqlNotesRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.ExecutiveSummaryHighlightsExcel>();
        // Denial Dashboard reads go straight to SQL (the same queries LRN.ReportsApi runs
        // for the page) — the HTTP client mints its JWT from the signed-in HttpContext,
        // which a background service does not have.
        // TRANSIENT on purpose: DenialDashboardReportGenerator points each instance at one
        // lab's database via LabConnectionResolver, so instances must not be shared between
        // concurrently generating reports.
        services.AddTransient<LabMetricsDashboard.Services.SqlDenialRecordRepository>();
        // Denial Summary (DenialClaimReport page) — stateless, takes the lab connection per call.
        services.AddSingleton<LabMetricsDashboard.Services.SqlDenialClaimReportRepository>();
        services.AddSingleton<LabMetricsDashboard.Services.IDenialClaimReportRepository>(sp =>
            sp.GetRequiredService<LabMetricsDashboard.Services.SqlDenialClaimReportRepository>());
        return services;
    }

    /// <summary>
    /// The five page reports a weekly snapshot captures, each registered as itself and as an
    /// <see cref="IReportSnapshotSource"/>. The report worker registers the same classes as
    /// <see cref="IReportGenerator"/> for the queued Excel exports.
    /// </summary>
    public static IServiceCollection AddReportSnapshotSources(this IServiceCollection services)
    {
        services.AddSingleton<ExecutiveSummaryReportGenerator>();
        services.AddSingleton<LisSummaryReportGenerator>();
        services.AddSingleton<ProductionReportGenerator>();
        services.AddSingleton<CollectionReportGenerator>();
        services.AddSingleton<DenialSummaryReportGenerator>();
        services.AddSingleton<IReportSnapshotSource>(sp => sp.GetRequiredService<ExecutiveSummaryReportGenerator>());
        services.AddSingleton<IReportSnapshotSource>(sp => sp.GetRequiredService<LisSummaryReportGenerator>());
        services.AddSingleton<IReportSnapshotSource>(sp => sp.GetRequiredService<ProductionReportGenerator>());
        services.AddSingleton<IReportSnapshotSource>(sp => sp.GetRequiredService<CollectionReportGenerator>());
        services.AddSingleton<IReportSnapshotSource>(sp => sp.GetRequiredService<DenialSummaryReportGenerator>());
        return services;
    }
}
