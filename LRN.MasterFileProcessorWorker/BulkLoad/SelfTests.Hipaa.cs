using System.Text.Json;
using LRN.MasterFileProcessorWorker.Logging;
using LRN.MasterFileProcessorWorker.Security;
using LRN.MasterFileProcessorWorker.Snapshots;
using Microsoft.Extensions.Options;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// Self-tests for the HIPAA controls in <c>Security/</c> (checklist section 2). Every value here is
/// synthetic: the SSNs start 000, which is never issued, and the names are obviously not people.
/// </summary>
public static partial class SelfTests
{
    // ---------------- MF-07 / CC-18: no row values in logs ----------------

    private static void PhiRedactorStripsRowValues()
    {
        static string S(string text) => PhiRedactor.Scrub(text)!;

        var bulk = S("The given value 'TESTPATIENT, ALPHA' of type String from the data source cannot be converted to type int of the specified target column.");
        Check("Redactor: SqlBulkCopy value removed", !bulk.Contains("TESTPATIENT") && bulk.Contains("value '[REDACTED]' of type String"), bulk);

        var convert = S("Conversion failed when converting the varchar value 'ZZTEST' to data type int.");
        Check("Redactor: SQL conversion value removed", !convert.Contains("ZZTEST") && convert.Contains("to data type int"), convert);

        var truncated = S("String or binary data would be truncated in table 'CoveLRN.dbo.ClaimLevelData', column 'PatientName'. Truncated value: '1 TEST ST'.");
        Check("Redactor: truncated value removed, table and column kept",
            !truncated.Contains("1 TEST ST") && truncated.Contains("column 'PatientName'") && truncated.Contains("dbo.ClaimLevelData"), truncated);

        var duplicate = S("Violation of PRIMARY KEY constraint 'PK_X'. The duplicate key value is (A123, 01/02/1960).");
        Check("Redactor: duplicate key values removed", !duplicate.Contains("A123") && !duplicate.Contains("1960"), duplicate);

        var format = S("The input string 'ZZTEST' was not in a correct format.");
        Check("Redactor: FormatException value removed", !format.Contains("ZZTEST"), format);

        var apostrophe = S("The given value 'O'TESTNAME' of type String cannot be converted.");
        Check("Redactor: a value with an apostrophe is removed whole", !apostrophe.Contains("TESTNAME"), apostrophe);

        var ssn = S("Lab 4: row 12 has 000-12-3456 in column Notes");
        Check("Redactor: SSN anywhere is removed, row and column kept",
            !ssn.Contains("000-12-3456") && ssn.Contains("row 12") && ssn.Contains("column Notes"), ssn);

        var clean = "Lab 18 [LineLevel]: loaded 1200 rows into dbo.LineLevelData in 950 ms.";
        Check("Redactor: a message with no values is unchanged", S(clean) == clean);
        Check("Redactor: null stays null", PhiRedactor.Scrub(null) is null);
    }

    private static void PhiRedactorWrapsExceptions()
    {
        Exception thrown;
        try
        {
            try { throw new FormatException("The input string 'ZZINNER' was not in a correct format."); }
            catch (Exception inner) { throw new InvalidOperationException("The given value 'ZZOUTER' of type String cannot be converted.", inner); }
        }
        catch (Exception ex) { thrown = ex; }

        var wrapped = PhiRedactor.Wrap(thrown)!;
        var text = wrapped.ToString();

        Check("Redactor: wrapped exception text carries no values", !text.Contains("ZZOUTER") && !text.Contains("ZZINNER"), text);
        Check("Redactor: wrapped exception keeps the stack trace", text.Contains(nameof(PhiRedactorWrapsExceptions)));
        Check("Redactor: wrapped exception Message is scrubbed", !wrapped.Message.Contains("ZZOUTER"));
        Check("Redactor: wrapping twice is a no-op", ReferenceEquals(PhiRedactor.Wrap(wrapped), wrapped));
    }

    private static void MalformedCsvErrorCarriesNoRowContent()
    {
        var folder = TempFolder();
        try
        {
            var csv = Path.Combine(folder, "claim.csv");
            File.WriteAllText(csv, "ClaimID,PatientName,ChargeAmount\nC-1,\"ZZTEST\"PATIENT,37\n");

            var fields = new List<FieldMapping>
            {
                new() { CsvHeader = "ClaimID", SqlColumn = "ClaimID", IncludeInHash = true },
                new() { CsvHeader = "PatientName", SqlColumn = "PatientName" },
                new() { CsvHeader = "ChargeAmount", SqlColumn = "ChargeAmount" }
            };
            var audit = new AuditColumns.AuditValues(1, "R1", "W1", "/sp", "claim.csv", FileTypes.ClaimLevel, 4, "Cove");

            string? message = null;
            using (var reader = new CsvBulkDataReader(csv, fields, audit))
            {
                try { while (reader.Read()) { } }
                catch (InvalidDataException ex) { message = ex.ToString(); }
            }

            Check("Malformed CSV: the load fails", message is not null);
            Check("Malformed CSV: the error names line and file, not the row",
                message is not null && !message.Contains("ZZTEST") && message.Contains("line 2") && message.Contains("claim.csv"), message);
        }
        finally
        {
            TryDelete(folder);
        }
    }

    // ---------------- CC-08 / MF-04: SQL connection policy ----------------

    private static void SqlConnectionPolicyFindings()
    {
        const string key = "ConnectionStrings:TestLab";

        var (fixedUp, plain) = SqlConnectionPolicy.Evaluate(key,
            "Server=tcp:example.database.windows.net,1433;Initial Catalog=TestLab_LRN;User ID=svc;Password=x;Encrypt=False;");
        Check("SQL policy: Encrypt=False is switched on and reported as corrected",
            fixedUp is not null && fixedUp.Contains("Encrypt=True", StringComparison.OrdinalIgnoreCase) &&
            plain.Count == 1 && plain[0].Corrected, fixedUp);
        Check("SQL policy: findings never carry the password", plain.All(f => !f.Problem.Contains("Password") && !f.Target.Contains("svc")));

        var (_, trust) = SqlConnectionPolicy.Evaluate(key,
            "Server=example;Initial Catalog=TestLab_LRN;User ID=svc;Password=x;Encrypt=True;TrustServerCertificate=True;");
        Check("SQL policy: TrustServerCertificate=True is reported, not changed",
            trust.Count == 1 && !trust[0].Corrected && trust[0].Problem.Contains("TrustServerCertificate"));

        var (_, sa) = SqlConnectionPolicy.Evaluate(key, "Server=example;Initial Catalog=TestLab_LRN;User Id=sa;Password=x;");
        Check("SQL policy: an sa login is reported", sa.Count == 1 && sa[0].Problem.Contains("'sa'"));

        var (unchanged, clean) = SqlConnectionPolicy.Evaluate(key,
            "Server=example;Initial Catalog=TestLab_LRN;Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;");
        Check("SQL policy: a compliant string has no findings and is not rewritten", clean.Count == 0 && unchanged is null);

        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                [key] = "Server=example;Initial Catalog=TestLab_LRN;User ID=svc;Password=x;Encrypt=False;"
            })
            .Build();

        var applied = SqlConnectionPolicy.Apply(configuration);
        Check("SQL policy: Apply rewrites the configured value in place",
            applied.Count == 1 && configuration.GetConnectionString("TestLab")!.Contains("Encrypt=True", StringComparison.OrdinalIgnoreCase));

        Check("SQL policy: Enforce unless Warn is configured",
            SqlConnectionPolicy.IsEnforced(new ConfigurationBuilder().Build()) &&
            !SqlConnectionPolicy.IsEnforced(new ConfigurationBuilder()
                .AddInMemoryCollection(new Dictionary<string, string?> { [SqlConnectionPolicy.ModeKey] = "warn" }).Build()));
    }

    // ---------------- MF-05: cross-lab misrouting ----------------

    private static void LabDatabaseGuardRefusesAnotherLabsDatabase()
    {
        Check("Lab guard: the lab's own database passes (case-insensitive)",
            LabDatabaseGuard.Check(4, "CoveLRN", "covelrn") is null);

        var other = LabDatabaseGuard.Check(4, "CoveLRN", "Certus_LRN");
        Check("Lab guard: another lab's database is refused, naming both",
            other is not null && other.Contains("Certus_LRN") && other.Contains("CoveLRN"), other);

        Check("Lab guard: a mapping with no DatabaseName is refused", LabDatabaseGuard.Check(4, null, "CoveLRN") is not null);
        Check("Lab guard: a connection with no database is refused", LabDatabaseGuard.Check(4, "CoveLRN", "") is not null);

        bool threw;
        try
        {
            LabDatabaseGuard.EnsureConnectionTargetsLab(4, "CoveLRN",
                "Server=example;Initial Catalog=Certus_LRN;User ID=svc;Password=x;");
            threw = false;
        }
        catch (LabRoutingException) { threw = true; }
        Check("Lab guard: EnsureConnectionTargetsLab throws LabRoutingException on a mismatch", threw);
    }

    /// <summary>
    /// Every lab's mapping must name its database, and the eight that used to name a database that
    /// does not exist must now match the real one (checked against kv-lrnmetrics-prod with --diagnose,
    /// Nov 2026) - otherwise MF-05 refuses every load for that lab.
    /// </summary>
    private static void EveryLabMappingNamesItsDatabase()
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "Schemas", "LabMappings");
        var options = new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };
        var byLab = new Dictionary<int, string?>();

        foreach (var file in Directory.EnumerateFiles(folder, "*.json"))
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(file), options);
            var root = doc.RootElement;

            if (root.TryGetProperty("LabId", out var id) && id.ValueKind == JsonValueKind.Number)
                byLab[id.GetInt32()] = root.TryGetProperty("DatabaseName", out var db) ? db.GetString() : null;
        }

        var missing = byLab.Where(kv => string.IsNullOrWhiteSpace(kv.Value)).Select(kv => kv.Key).ToList();
        Check("Lab mappings: every lab names its DatabaseName", byLab.Count > 0 && missing.Count == 0, string.Join(", ", missing));

        foreach (var (labId, expected) in new[]
                 {
                     (4, "CoveLRN"), (2, "InHealthDTRLRN"), (18, "Certus_LRN"), (13, "PCRLOA_LRN"),
                     (26, "AnalyzePathology"), (27, "WellHealth"), (28, "CoreBio"), (29, "TexasDiagnostic")
                 })
        {
            byLab.TryGetValue(labId, out var actual);
            Check($"Lab mappings: lab {labId} DatabaseName is {expected}", actual == expected, actual);
        }
    }

    // ---------------- MF-08: PHI in file names ----------------

    private static void PhiFileNameGuardFindsIdentifiersNotDates()
    {
        foreach (var name in new[]
                 {
                     "Beech Tree_Production Report.xlsx",
                     "2. Internal LRN Client Folders/BeachTree/Reporting/02.Master Files/2026/02.February/02.06.2026 - 02.12.2026/Beech Tree_Production Report.xlsx",
                     "Certus_Master File_20260206.xlsx",
                     "Certus_Master File_202602061530.xlsx",
                     "Report_02062026.xlsx",
                     "R20260213BTL0001_Line Level.csv"
                 })
        {
            Check($"File name guard: allows '{name[^Math.Min(name.Length, 40)..]}'", PhiFileNameGuard.FindIdentifier(name) is null,
                PhiFileNameGuard.FindIdentifier(name));
        }

        var ssn = PhiFileNameGuard.FindIdentifier("Claims_000-12-3456.xlsx");
        Check("File name guard: refuses an SSN-shaped name without repeating it", ssn is not null && !ssn.Contains("3456"), ssn);
        Check("File name guard: refuses SSN with underscores or spaces",
            PhiFileNameGuard.FindIdentifier("x_000_12_3456.xlsx") is not null && PhiFileNameGuard.FindIdentifier("x 000 12 3456.xlsx") is not null);

        var member = PhiFileNameGuard.FindIdentifier("Appeal_000123456789.pdf");
        Check("File name guard: refuses a 12-digit non-date number without repeating it",
            member is not null && !member.Contains("000123456789"), member);
    }

    // ---------------- MF-03: orphaned temp files ----------------

    private static void TempFileJanitorRemovesOnlyOrphanedTempFiles()
    {
        var root = TempFolder();
        var modeMedianTemp = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid():N}_Median.xlsx");

        try
        {
            var outputs = Path.Combine(root, "Automation");
            var watch = Path.Combine(outputs, "LRN-Input");
            var snapshotWork = Path.Combine(root, "SnapWork");
            var old = DateTime.UtcNow.AddHours(-30);

            string Make(string path, DateTime? writtenUtc = null)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, "synthetic");
                File.SetLastWriteTimeUtc(path, writtenUtc ?? old);
                return path;
            }

            var rawWorkbook = Make(Path.Combine(outputs, "LRN-RAWFILE", "02.February", "W1", "Cove_Master.xlsx"));
            var rawCsv = Make(Path.Combine(outputs, "LRN-RAWFILE", "02.February", "W1", "Cove_Master_LineLevel_RAW.csv"));
            var freshRaw = Make(Path.Combine(outputs, "LRN-RAWFILE", "02.February", "W2", "Cove_Master.xlsx"), DateTime.UtcNow);
            var archived = Make(Path.Combine(outputs, "LRN-RAWFILE", "Archive", "02.February", "W1", "Cove_Master.xlsx"));
            var published = Make(Path.Combine(watch, "Cove", "2026", "02.February", "W1", "R1_Cove_Line Level_W1.csv"));
            var partial = Make(Path.Combine(watch, "Cove", "2026", "02.February", "W1", "LIMS.xlsx.download"));
            var staging = Path.Combine(watch, "Cove", "~staging_R1");
            Make(Path.Combine(staging, "R1_Cove_Claim Level_W1.csv"));
            Directory.SetLastWriteTimeUtc(staging, old);
            var parquet = Make(Path.Combine(snapshotWork, "4_R1", "x.parquet"));
            var notOurs = Make(Path.Combine(snapshotWork, "readme.txt"));
            Make(modeMedianTemp);

            var janitor = new TempFileJanitor(
                Options.Create(new TempFileOptions()),
                Options.Create(new ImportOptions { WatchFolder = watch, ReportOutputsRoot = outputs }),
                Options.Create(new MasterDataSnapshotOptions { WorkFolder = snapshotWork }),
                new NullFileLog(),
                NullLogger<TempFileJanitor>.Instance);

            var removed = janitor.Sweep(DateTime.UtcNow.AddHours(-24));

            Check("Temp sweep: orphaned raw workbook and RAW CSV removed", !File.Exists(rawWorkbook) && !File.Exists(rawCsv));
            Check("Temp sweep: stale staging folder and partial download removed", !Directory.Exists(staging) && !File.Exists(partial));
            Check("Temp sweep: orphaned Mode/Median temp and snapshot parquet removed", !File.Exists(modeMedianTemp) && !File.Exists(parquet));
            Check("Temp sweep: Archive, published outputs, fresh files and other files kept",
                File.Exists(archived) && File.Exists(published) && File.Exists(freshRaw) && File.Exists(notOurs));
            // At least: %TEMP% is shared, so older orphans from real runs may be swept as well.
            Check("Temp sweep: reports what it removed", removed >= 6, removed.ToString());
        }
        finally
        {
            TryDelete(root);
            try { File.Delete(modeMedianTemp); } catch { /* best effort */ }
        }
    }

    private sealed class NullFileLog : ILoggerService
    {
        public void Info(string message) { }
        public void Warn(string message) { }
        public void Error(string message, Exception? ex = null) { }
        public void Fatal(string message, Exception? ex = null) { }
    }
}
