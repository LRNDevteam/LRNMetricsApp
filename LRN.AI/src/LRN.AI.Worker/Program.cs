using LRN.AI.Application;
using LRN.AI.Infrastructure;

// Phase 1 scaffold. Document ingestion, text extraction / OCR, chunking, embedding and reprocessing jobs
// (Phase 3) are added under Jobs/ as hosted services; until then the host only validates its configuration.
var builder = Host.CreateApplicationBuilder(args);
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: true);
builder.Configuration.AddEnvironmentVariables();

builder.Services.AddLrnAiApplication();
builder.Services.AddLrnAiInfrastructure(builder.Configuration);

builder.Build().Run();
