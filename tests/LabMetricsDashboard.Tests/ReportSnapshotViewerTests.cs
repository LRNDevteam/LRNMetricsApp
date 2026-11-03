using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services.ReportSnapshots;
using LabMetricsDashboard.ViewModels;
using Parquet;
using Parquet.Schema;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// Master Values > Report Snapshots: a report snapshot's page model must bind back to the page's own view
/// model with nothing lost, or the report view would silently show less than the page showed that week.
/// </summary>
public sealed class ReportSnapshotViewerTests
{
    public static IEnumerable<object[]> ModelTypes =>
    [
        [typeof(PhiExecutiveSummaryViewModel)],
        [typeof(LisSummaryResult)],
        [typeof(LRN.ProductionReports.Models.ProductionReportViewModel)],
        [typeof(CollectionSummaryViewModel)],
        [typeof(DenialClaimReportViewModel)],
        [typeof(DenialInsightSnapshotModel)],
        [typeof(ReportInsightsSnapshotModel)],
    ];

    [Theory]
    [MemberData(nameof(ModelTypes))]
    public void Every_report_view_model_round_trips_through_the_snapshot_json(Type type)
    {
        var model = Sample.Create(type, 0);
        Assert.NotNull(model);

        var json = JsonSerializer.Serialize(model, type, ReportSnapshotJson.Options);
        // The sample really is populated (nested rows, pivots), so the comparison below means something.
        Assert.True(json.Length > 400, $"{type.Name} sample is only {json.Length} chars: {json}");
        var back = JsonSerializer.Deserialize(json, type, ReportSnapshotJson.Options);
        var again = JsonSerializer.Serialize(back, type, ReportSnapshotJson.Options);

        Assert.Equal(json, again);
    }

    [Fact]
    public void Executive_summary_keeps_its_year_month_columns_and_cells()
    {
        var vm = new PhiExecutiveSummaryViewModel
        {
            YearMonthColumns = [(2026, 9), (2026, 10), (0, 0)],
            Rows = [new ExecSummaryRow { RowCode = "A", Category = "LIS", ValuesByYearMonth = new() { [(2026, 10)] = 10m, [(0, 0)] = 15m } }]
        };

        var back = JsonSerializer.Deserialize<PhiExecutiveSummaryViewModel>(
            JsonSerializer.Serialize(vm, ReportSnapshotJson.Options), ReportSnapshotJson.Options)!;

        Assert.Equal(vm.YearMonthColumns, back.YearMonthColumns);
        Assert.Equal(10m, back.Rows[0].ValuesByYearMonth[(2026, 10)]);
        Assert.Equal(15m, back.Rows[0].Total);
    }

    [Fact]
    public void A_page_model_file_binds_to_its_type_and_each_read_gets_its_own_model()
    {
        var bytes = PageModelFile("LabMetricsDashboard.ViewModels.DenialClaimReportViewModel",
            new DenialClaimReportViewModel { CurrentLab = "TexasDiagnostic", TotalClaims = 42 });

        var page = ReportPageSnapshotReader.Parse(bytes);
        var first = page.Bind();
        var second = page.Bind();

        var model = Assert.IsType<DenialClaimReportViewModel>(first.BoundModel);
        Assert.Equal(42, model.TotalClaims);
        Assert.Equal("R1", first.RunId);
        Assert.NotSame(first.BoundModel, second.BoundModel);
    }

    [Fact]
    public void Denial_insight_snapshots_taken_under_the_generators_old_type_name_still_bind()
    {
        var bytes = PageModelFile("LRN.SnapshotGenerator.DenialInsightSnapshotModel",
            new DenialInsightSnapshotModel { CurrentLab = "TexasDiagnostic" });

        Assert.IsType<DenialInsightSnapshotModel>(ReportPageSnapshotReader.Parse(bytes).Bind().BoundModel);
    }

    [Fact]
    public void A_model_type_outside_the_known_reports_is_refused()
    {
        var bytes = PageModelFile("System.IO.FileInfo", new { Name = "x" });
        Assert.Throws<NotSupportedException>(() => ReportPageSnapshotReader.Parse(bytes));
    }

    [Fact]
    public async Task A_parquet_page_is_read_across_row_groups()
    {
        var id = new DataField<int?>("Id");
        var name = new DataField<string>("Name");
        var amount = new DataField<decimal?>("Amount");
        var schema = new ParquetSchema(id, name, amount);

        using var stream = new MemoryStream();
        await using (var writer = await ParquetWriter.CreateAsync(schema, stream))
        {
            for (int g = 0; g < 2; g++)
            {
                using var group = writer.CreateRowGroup();
                var ids = Enumerable.Range(g * 3 + 1, 3).Select(i => (int?)i).ToArray();
                await group.WriteAsync<int>(id, ids.AsMemory());
                await group.WriteAsync(name, ids.Select(i => i == 5 ? null : "N" + i).ToArray()!);
                await group.WriteAsync<decimal>(amount, ids.Select(i => (decimal?)(i * 1.25m)).ToArray().AsMemory());
            }
        }

        var page = await ParquetTableReader.ReadPageAsync(stream.ToArray(), offset: 2, limit: 3, CancellationToken.None);

        Assert.Equal(6, page.TotalRows);
        Assert.Equal(2, page.RowGroups);
        Assert.Equal(["Id", "Name", "Amount"], page.Columns.Select(c => c.Name));
        Assert.True(page.Columns[0].IsNumeric);
        Assert.Equal([3, 4, 5], page.Rows.Select(r => (int)r[0]!));
        Assert.Null(page.Rows[2][1]);
        Assert.Equal(5m, page.Rows[1][2]);
    }

    private static byte[] PageModelFile(string modelType, object model)
    {
        var json = JsonSerializer.Serialize(new
        {
            Format = "LRN.ReportPageSnapshot",
            FormatVersion = 1,
            ReportCode = "DENIALSUMMARY",
            LabKey = "TexasDiagnostic",
            RunId = "R1",
            WeekFolder = "10.16.2026 - 10.22.2026",
            ModelType = modelType,
            Model = model
        }, ReportSnapshotJson.Options);
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Fastest, leaveOpen: true))
            gzip.Write(System.Text.Encoding.UTF8.GetBytes(json));
        return output.ToArray();
    }

    /// <summary>
    /// A populated instance of a view model: every settable member and constructor argument filled, every
    /// collection with one element, so a member the snapshot JSON cannot carry shows up as a difference.
    /// </summary>
    internal static class Sample
    {
        private const int MaxDepth = 6;

        public static object? Create(Type type, int depth)
        {
            var underlying = Nullable.GetUnderlyingType(type);
            if (underlying is not null) return Create(underlying, depth);

            if (type == typeof(string)) return "x";
            if (type == typeof(bool)) return true;
            if (type == typeof(int)) return 7;
            if (type == typeof(long)) return 7L;
            if (type == typeof(short)) return (short)7;
            if (type == typeof(byte)) return (byte)7;
            if (type == typeof(decimal)) return 12.5m;
            if (type == typeof(double)) return 1.5d;
            if (type == typeof(float)) return 1.5f;
            if (type == typeof(DateTime)) return new DateTime(2026, 10, 16, 0, 0, 0, DateTimeKind.Unspecified);
            if (type == typeof(DateOnly)) return new DateOnly(2026, 10, 16);
            if (type == typeof(TimeSpan)) return TimeSpan.FromHours(1);
            if (type == typeof(Guid)) return Guid.Empty;
            if (type == typeof(object)) return "x";
            if (type.IsEnum) return Enum.GetValues(type).GetValue(0);
            if (typeof(Delegate).IsAssignableFrom(type)) return null;
            // Past the depth limit collections are empty, not null - real data never has a null row list.
            var fill = depth <= MaxDepth;

            if (type.IsValueType && type.IsGenericType && type.FullName!.StartsWith("System.ValueTuple`", StringComparison.Ordinal))
                return Activator.CreateInstance(type, type.GetGenericArguments().Select(a => Create(a, depth + 1)).ToArray());

            if (type.IsArray)
            {
                var item = fill ? Create(type.GetElementType()!, depth + 1) : null;
                var array = Array.CreateInstance(type.GetElementType()!, item is null ? 0 : 1);
                if (item is not null) array.SetValue(item, 0);
                return array;
            }

            var dictionary = GenericInterface(type, typeof(IDictionary<,>)) ?? GenericInterface(type, typeof(IReadOnlyDictionary<,>));
            if (dictionary is not null)
            {
                var args = dictionary.GetGenericArguments();
                var target = type.IsInterface ? typeof(Dictionary<,>).MakeGenericType(args) : type;
                var instance = (IDictionary)Activator.CreateInstance(target)!;
                var key = fill ? Create(args[0], depth + 1) : null;
                var value = key is null ? null : Create(args[1], depth + 1);
                if (key is not null && (value is not null || Nullable.GetUnderlyingType(args[1]) is not null)) instance[key] = value;
                return instance;
            }

            var enumerable = type == typeof(string) ? null : GenericInterface(type, typeof(IEnumerable<>));
            if (enumerable is not null)
            {
                var element = enumerable.GetGenericArguments()[0];
                var target = type.IsInterface ? typeof(List<>).MakeGenericType(element) : type;
                var instance = (IList)Activator.CreateInstance(target)!;
                var item = fill ? Create(element, depth + 1) : null;
                if (item is not null) instance.Add(item);
                return instance;
            }

            if (!fill || type.IsInterface || type.IsAbstract) return null;

            object instanceObj;
            var parameterless = type.GetConstructor(Type.EmptyTypes);
            if (parameterless is not null)
                instanceObj = parameterless.Invoke(null);
            else
            {
                var ctor = type.GetConstructors().OrderByDescending(c => c.GetParameters().Length).First();
                instanceObj = ctor.Invoke(ctor.GetParameters().Select(p => Create(p.ParameterType, depth + 1)).ToArray());
            }

            foreach (var p in type.GetProperties(BindingFlags.Public | BindingFlags.Instance))
            {
                if (p.SetMethod is not { IsPublic: true } || p.GetIndexParameters().Length > 0) continue;
                var value = Create(p.PropertyType, depth + 1);
                if (value is not null || !p.PropertyType.IsValueType) p.SetValue(instanceObj, value);
            }
            return instanceObj;
        }

        private static Type? GenericInterface(Type type, Type generic) =>
            type.IsGenericType && type.GetGenericTypeDefinition() == generic
                ? type
                : type.GetInterfaces().FirstOrDefault(i => i.IsGenericType && i.GetGenericTypeDefinition() == generic);
    }
}
