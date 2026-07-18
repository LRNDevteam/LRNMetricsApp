using LRN.PayerPolicyMapper;
using LRN.PayerPolicyMapper.Core;
using LRN.PayerPolicyMapper.Core.Abstractions;
using LRN.PayerPolicyMapper.Core.Data;

var host = Host.CreateDefaultBuilder(args)
    .UseContentRoot(AppContext.BaseDirectory)
    // Secrets (connection strings) live in appsettings.Local.json, which is gitignored.
    // The tracked appsettings.json must never contain credentials.
    .ConfigureAppConfiguration(cfg => cfg.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: true))
    .UseWindowsService(o => o.ServiceName = "LRN - Payer Policy Mapper")
    .ConfigureLogging((context, logging) =>
    {
        logging.ClearProviders();
        logging.AddConsole();
        if (OperatingSystem.IsWindows()) logging.AddEventLog();

        // Rolling daily file log (mapper-yyyy-MM-dd.log) configured via Logging:File, same
        // convention as LRN.ReportsApi. Never fail service startup because of the file logger.
        var fileSection = context.Configuration.GetSection("Logging:File");
        try
        {
            logging.AddProvider(new FileLoggerProvider(new FileLoggerOptions
            {
                LogDirectory = fileSection["LogDirectory"] ?? "Logs",
                MinLevel = Enum.TryParse<LogLevel>(fileSection["LogLevel"], true, out var fileLevel) ? fileLevel : LogLevel.Information,
                RetainDays = int.TryParse(fileSection["RetainDays"], out var retainDays) ? retainDays : 30
            }));
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Payer mapper file logger initialization failed: {ex}");
        }
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
        services.AddSingleton<IPayerMapperRunRepository>(_ => new SqlPayerMapperRunRepository(connectionString));
        services.AddSingleton<INotificationService>(sp => new PayerMasterNotificationService(
            connectionString, sp.GetRequiredService<ILogger<PayerMasterNotificationService>>()));
        services.AddSingleton<IPayerPolicyIndexProvider, CachedPayerPolicyIndexProvider>();
        services.AddSingleton<MatchingPipeline>();

        services.AddHostedService<Worker>();
    })
    .Build();

await host.RunAsync();
