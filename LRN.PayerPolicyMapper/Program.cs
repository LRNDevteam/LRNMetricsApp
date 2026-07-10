using LRN.PayerPolicyMapper;
using LRN.PayerPolicyMapper.Core;
using LRN.PayerPolicyMapper.Core.Abstractions;
using LRN.PayerPolicyMapper.Core.Data;

var host = Host.CreateDefaultBuilder(args)
    .UseContentRoot(AppContext.BaseDirectory)
    .UseWindowsService(o => o.ServiceName = "LRN - Payer Policy Mapper")
    .ConfigureLogging((context, logging) =>
    {
        logging.ClearProviders();
        logging.AddConsole();
        if (OperatingSystem.IsWindows()) logging.AddEventLog();
    })
    .ConfigureServices((context, services) =>
    {
        var connectionString = context.Configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster (same as LRN.ReportsApi).");

        services.Configure<PayerMapperOptions>(context.Configuration.GetSection("PayerMapper"));
        services.AddSingleton(context.Configuration.GetSection("PayerMatching").Get<MatchingOptions>() ?? new MatchingOptions());

        services.AddSingleton<IReferenceDataRepository>(_ => new SqlReferenceDataRepository(connectionString));
        services.AddSingleton<ILabInsuranceRepository>(_ => new SqlLabInsuranceRepository(connectionString));
        services.AddSingleton<IAuditRepository>(_ => new SqlAuditRepository(connectionString));
        services.AddSingleton<INotificationService>(sp => new PayerMasterNotificationService(
            connectionString, sp.GetRequiredService<ILogger<PayerMasterNotificationService>>()));
        services.AddSingleton<IPayerPolicyIndexProvider, CachedPayerPolicyIndexProvider>();
        services.AddSingleton<MatchingPipeline>();

        services.AddHostedService<Worker>();
    })
    .Build();

await host.RunAsync();
