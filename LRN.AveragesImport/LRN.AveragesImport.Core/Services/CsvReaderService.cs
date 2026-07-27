using System.Globalization;
using CsvHelper;
using CsvHelper.Configuration;
using LRN.AveragesImport.Core.Configuration;
using LRN.AveragesImport.Core.Csv;
using LRN.AveragesImport.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace LRN.AveragesImport.Core.Services;

public sealed class CsvParseResult<T>
{
    public List<T> Records { get; } = new();
    public int BadRowCount { get; set; }
    public int TotalDataRows { get; set; }
}

public interface ICsvReaderService
{
    CsvParseResult<CptAverageRecord> ReadCptAverages(string filePath);
    CsvParseResult<PanelAverageRecord> ReadPanelAverages(string filePath);
}

public sealed class CsvReaderService : ICsvReaderService
{
    private readonly ILogger<CsvReaderService> _logger;
    private readonly IOptions<ImportSettings> _settings;

    public CsvReaderService(ILogger<CsvReaderService> logger, IOptions<ImportSettings> settings)
    {
        _logger = logger;
        _settings = settings;
    }

    public CsvParseResult<CptAverageRecord> ReadCptAverages(string filePath)
        => Read<CptAverageRecord, CptAverageMap>(filePath, validator: null);

    // A blank PayerID is imported as NULL rather than treated as a bad row — PanelAverage.PayerID
    // is nullable in SQL, so the row is still valid data. Same for CptAverage.Global_Payer_ID.
    public CsvParseResult<PanelAverageRecord> ReadPanelAverages(string filePath)
        => Read<PanelAverageRecord, PanelAverageMap>(filePath, validator: null);

    private CsvParseResult<T> Read<T, TMap>(string filePath, Func<T, string?>? validator)
        where TMap : ClassMap, new()
    {
        var maxBadRows = _settings.Value.MaxBadRowsPerFile;
        var result = new CsvParseResult<T>();

        var config = new CsvConfiguration(CultureInfo.InvariantCulture)
        {
            TrimOptions = TrimOptions.Trim,
            DetectColumnCountChanges = false,
            ShouldSkipRecord = args =>
                args.Row.Parser.Record is null ||
                args.Row.Parser.Record.All(string.IsNullOrWhiteSpace)
        };

        using var reader = new StreamReader(filePath);
        using var csv = new CsvReader(reader, config);
        csv.Context.TypeConverterCache.AddConverter<DateTime?>(new BlankToNullDateConverter());
        csv.Context.TypeConverterCache.AddConverter<decimal?>(new BlankToNullDecimalConverter());
        csv.Context.TypeConverterCache.AddConverter<int?>(new BlankToNullIntConverter());
        csv.Context.RegisterClassMap<TMap>();

        if (!csv.Read())
            throw new InvalidDataException($"File is empty: {filePath}");
        csv.ReadHeader();
        csv.ValidateHeader<T>(); // missing/misnamed headers fail the whole file

        while (csv.Read())
        {
            result.TotalDataRows++;
            try
            {
                var record = csv.GetRecord<T>();
                var error = validator?.Invoke(record);
                if (error is not null)
                {
                    RecordBadRow(result, filePath, csv.Parser.Row, error, maxBadRows);
                    continue;
                }
                result.Records.Add(record);
            }
            catch (CsvHelperException ex)
            {
                RecordBadRow(result, filePath, csv.Parser.Row, ex.InnerException?.Message ?? ex.Message, maxBadRows);
            }
        }

        _logger.LogInformation(
            "Parsed {File}: {Good} rows ok, {Bad} bad rows",
            Path.GetFileName(filePath), result.Records.Count, result.BadRowCount);

        return result;
    }

    private void RecordBadRow<T>(CsvParseResult<T> result, string filePath, int lineNumber, string reason, int maxBadRows)
    {
        result.BadRowCount++;
        _logger.LogWarning("Bad row in {File} at line {Line}: {Reason}", Path.GetFileName(filePath), lineNumber, reason);

        if (result.BadRowCount > maxBadRows)
            throw new InvalidDataException(
                $"Aborting {Path.GetFileName(filePath)}: bad row count exceeded threshold of {maxBadRows}.");
    }
}
