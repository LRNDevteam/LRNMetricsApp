using System.Text;
using LRN.MasterFileProcessorWorker.ExcelValidation;

namespace LRN.MasterFileProcessorWorker.BulkLoad;

/// <summary>
/// Self-contained assertions for the bulk-copy pipeline, runnable without a test framework.
/// <para>
/// Run with: <c>LRN.MasterFileProcessorWorker.exe --selftest</c>. Exits 0 on pass, 1 on failure,
/// so it drops straight into CI.
/// </para>
/// <para>
/// This lives here rather than in an xunit project deliberately: adding xunit would mean new NuGet
/// packages, which the brief requires be raised first. Converting these to <c>[Fact]</c> methods is
/// mechanical once that is approved.
/// </para>
/// </summary>
public static class SelfTests
{
    private static int _passed;
    private static readonly List<string> Failures = new();

    public static int Run()
    {
        Console.WriteLine("BulkLoad self-tests");
        Console.WriteLine(new string('-', 70));

        RowHashDeterminism();
        RowHashIgnoresAuditAndUnflaggedFields();
        RowHashNormalization();
        RowHashDistinguishesDifferentRows();
        MappingValidationCatchesBadConfig();
        MappingValidationAcceptsGoodConfig();
        DisabledLevelIsNotValidated();
        AuditStampingAndCsvBinding();
        AdditionalFieldsCaptureUnmappedColumns();
        SensitiveColumnsAreNeverCaptured();
        ToggleSkipReasons();
        PerLevelCsvToggles();
        DerivedReportRules();
        AugustusPanelNewComesFromSourceColumn();
        EmptyRowsAreNotImported();
        RowsWithoutIdentityAreImportedAndCounted();

        Console.WriteLine(new string('-', 70));

        foreach (var failure in Failures)
            Console.WriteLine("FAIL  " + failure);

        Console.WriteLine($"{_passed} passed, {Failures.Count} failed.");
        return Failures.Count == 0 ? 0 : 1;
    }

    // ---------------- RowHash ----------------

    private static readonly List<FieldMapping> SampleFields = new()
    {
        new FieldMapping { CsvHeader = "ClaimID",      SqlColumn = "ClaimID",      IncludeInHash = true },
        new FieldMapping { CsvHeader = "ChargeAmount", SqlColumn = "ChargeAmount", IncludeInHash = true },
        new FieldMapping { CsvHeader = "DateofService",SqlColumn = "DateofService",IncludeInHash = true },
        new FieldMapping { CsvHeader = "Remarks",      SqlColumn = "Remarks",      IncludeInHash = false },
        new FieldMapping { CsvHeader = "LabID",        SqlColumn = "LabID",        IncludeInHash = false }
    };

    private static void RowHashDeterminism()
    {
        var hasher = new RowHasher(SampleFields);
        var row = new string?[] { "C-1", "37.00", "03/01/2026", "note", "20" };

        var a = hasher.Compute(row);
        var b = new RowHasher(SampleFields).Compute(row);

        Check("RowHash is deterministic across instances", a == b);
        Check("RowHash is 64 hex chars", a.Length == 64 && a.All(Uri.IsHexDigit));
    }

    private static void RowHashIgnoresAuditAndUnflaggedFields()
    {
        var hasher = new RowHasher(SampleFields);

        var a = hasher.Compute(new string?[] { "C-1", "37.00", "03/01/2026", "note one", "20" });
        var b = hasher.Compute(new string?[] { "C-1", "37.00", "03/01/2026", "note two", "99" });

        Check("RowHash ignores fields not flagged IncludeInHash", a == b);

        // LabID is an audit column: even flagged, it must not contribute.
        var withAudit = new List<FieldMapping>(SampleFields)
        {
            new FieldMapping { CsvHeader = "RowHash", SqlColumn = "RowHash", IncludeInHash = true }
        };

        Check("RowHash excludes pipeline-owned columns even when flagged",
            new RowHasher(withAudit).HashedFieldCount == 3);
    }

    private static void RowHashNormalization()
    {
        var hasher = new RowHasher(SampleFields);

        Check("RowHash: 37.00 == 37",
            hasher.Compute(new string?[] { "C-1", "37.00", "03/01/2026", "", "" }) ==
            hasher.Compute(new string?[] { "C-1", "37", "03/01/2026", "", "" }));

        Check("RowHash: 3/1/2026 == 03/01/2026",
            hasher.Compute(new string?[] { "C-1", "37", "3/1/2026", "", "" }) ==
            hasher.Compute(new string?[] { "C-1", "37", "03/01/2026", "", "" }));

        Check("RowHash: case and surrounding space are normalized",
            hasher.Compute(new string?[] { "  c-1 ", "37", "03/01/2026", "", "" }) ==
            hasher.Compute(new string?[] { "C-1", "37", "03/01/2026", "", "" }));

        Check("RowHash: null and empty are the same",
            hasher.Compute(new string?[] { null, "37", "03/01/2026", "", "" }) ==
            hasher.Compute(new string?[] { "", "37", "03/01/2026", "", "" }));
    }

    private static void RowHashDistinguishesDifferentRows()
    {
        var hasher = new RowHasher(SampleFields);

        Check("RowHash changes when a hashed value changes",
            hasher.Compute(new string?[] { "C-1", "37", "03/01/2026", "", "" }) !=
            hasher.Compute(new string?[] { "C-2", "37", "03/01/2026", "", "" }));

        // Guards against naive concatenation: "AB"+"C" must not collide with "A"+"BC".
        var two = new List<FieldMapping>
        {
            new FieldMapping { SqlColumn = "A", CsvHeader = "A", IncludeInHash = true },
            new FieldMapping { SqlColumn = "B", CsvHeader = "B", IncludeInHash = true }
        };
        var h = new RowHasher(two);

        Check("RowHash is not vulnerable to field-boundary collisions",
            h.Compute(new string?[] { "AB", "C" }) != h.Compute(new string?[] { "A", "BC" }));
    }

    // ---------------- mapping validation ----------------

    private static void MappingValidationCatchesBadConfig()
    {
        var folder = TempFolder();

        // BulkCopyToTable with no TargetTable, plus a duplicate SqlColumn and an audit collision.
        File.WriteAllText(Path.Combine(folder, "BadFieldMappings.json"), """
        {
          "LabId": 99,
          "LineLevel": {
            "Enabled": true,
            "CreateCsv": true,
            "BulkCopyToTable": true,
            "SqlTableName": "",
            "Fields": [
              { "CsvHeader": "A", "SqlColumn": "ClaimID", "IncludeInHash": true },
              { "CsvHeader": "B", "SqlColumn": "ClaimID", "IncludeInHash": false },
              { "CsvHeader": "C", "SqlColumn": "RowHash", "IncludeInHash": false }
            ]
          }
        }
        """);

        var loader = new LabMappingLoader(NullLogger<LabMappingLoader>.Instance);

        try
        {
            loader.LoadAll(folder);
            Check("Invalid mapping is rejected", false, "no exception thrown");
        }
        catch (LabMappingValidationException ex)
        {
            var text = string.Join(" | ", ex.Errors);
            Check("Missing SqlTableName is reported", text.Contains("SqlTableName", StringComparison.OrdinalIgnoreCase));
            Check("Duplicate SqlColumn is reported", text.Contains("duplicate SqlColumn", StringComparison.OrdinalIgnoreCase));
            Check("Audit-column collision is reported", text.Contains("stamped by the pipeline", StringComparison.OrdinalIgnoreCase));
            Check("Offending file is named", text.Contains("BadFieldMappings.json"));
        }
        finally
        {
            TryDelete(folder);
        }
    }

    private static void MappingValidationAcceptsGoodConfig()
    {
        var folder = TempFolder();

        File.WriteAllText(Path.Combine(folder, "GoodFieldMappings.json"), """
        {
          "LabId": 20,
          "LabName": "NorthWest",
          "DatabaseName": "NWL_LRN",
          "LineLevel": {
            "Enabled": true,
            "CreateCsv": true,
            "BulkCopyToTable": true,
            "SqlTableName": "dbo.LineLevelData",
            "BatchSize": 10000,
            "BulkCopyTimeoutSeconds": 900,
            "Fields": [ { "CsvHeader": "Claim ID", "SqlColumn": "ClaimID", "IncludeInHash": true } ]
          }
        }
        """);

        try
        {
            var configs = new LabMappingLoader(NullLogger<LabMappingLoader>.Instance).LoadAll(folder);

            Check("Valid mapping loads", configs.Count == 1);
            Check("LabId is read", configs[0].LabId == 20);
            Check("SqlTableName is read", configs[0].LineLevel!.SqlTableName == "dbo.LineLevelData");
            Check("BulkCopyToTable defaults to false when absent", configs[0].ClaimLevel is null);
        }
        finally
        {
            TryDelete(folder);
        }
    }

    private static void DisabledLevelIsNotValidated()
    {
        var folder = TempFolder();

        // Enabled=false, so the otherwise-invalid block must not fail startup.
        File.WriteAllText(Path.Combine(folder, "OffFieldMappings.json"), """
        {
          "LabId": 1,
          "LineLevel": {
            "Enabled": false,
            "BulkCopyToTable": true,
            "SqlTableName": "",
            "Fields": []
          }
        }
        """);

        try
        {
            var configs = new LabMappingLoader(NullLogger<LabMappingLoader>.Instance).LoadAll(folder);
            Check("A disabled level is not validated", configs.Count == 1);
        }
        catch (LabMappingValidationException)
        {
            Check("A disabled level is not validated", false, "validation ran on a disabled level");
        }
        finally
        {
            TryDelete(folder);
        }
    }

    // ---------------- audit stamping ----------------

    private static void AuditStampingAndCsvBinding()
    {
        var folder = TempFolder();
        var csv = Path.Combine(folder, "line.csv");

        File.WriteAllText(csv,
            "Claim ID,Charge Amount,Extra Column\r\n" +
            "C-1,37.00,ignored\r\n" +
            "C-2,53.00,ignored\r\n",
            new UTF8Encoding(true));

        var fields = new List<FieldMapping>
        {
            new() { CsvHeader = "Claim ID",      SqlColumn = "ClaimID",      IncludeInHash = true },
            new() { CsvHeader = "Charge Amount", SqlColumn = "ChargeAmount", IncludeInHash = true },
            new() { CsvHeader = "Absent Column", SqlColumn = "Missing",      IncludeInHash = false }
        };

        var audit = new AuditColumns.AuditValues(4242, "20260724R0044", "W1", "/sp/path", "line.csv",
            FileTypes.LineLevel, 20, "NorthWest");

        try
        {
            using var reader = new CsvBulkDataReader(csv, fields, audit);

            Check("Reader exposes fields + 9 audit columns", reader.FieldCount == fields.Count + 9);
            Check("Absent mapped header is reported", reader.MissingCsvHeaders.Count == 1);
            Check("Unmapped CSV column is reported",
                reader.UnmappedCsvHeaders.Count == 1 && reader.UnmappedCsvHeaders[0] == "Extra Column");

            var read = reader.Read();
            Check("First row reads", read);

            Check("CSV value binds by header", (string?)reader.GetValue(0) == "C-1");
            Check("Absent column binds to NULL", reader.IsDBNull(2));

            // Audit block: every one of the nine must be populated on every row.
            var auditStart = fields.Count;
            var allPopulated = Enumerable.Range(auditStart, 9).All(i => !reader.IsDBNull(i));
            Check("All 9 audit columns are populated", allPopulated);

            Check("FileLogId is stamped", Convert.ToInt64(reader.GetValue(auditStart)) == 4242);
            Check("RunId is stamped", (string?)reader.GetValue(auditStart + 1) == "20260724R0044");
            Check("FileType is stamped", (string?)reader.GetValue(auditStart + 5) == FileTypes.LineLevel);
            Check("LabID is stamped", Convert.ToInt32(reader.GetValue(auditStart + 7)) == 20);

            var hash1 = (string?)reader.GetValue(auditStart + 6);
            Check("RowHash is stamped", !string.IsNullOrWhiteSpace(hash1) && hash1!.Length == 64);

            reader.Read();
            var hash2 = (string?)reader.GetValue(auditStart + 6);
            Check("RowHash differs between different rows", hash1 != hash2);

            Check("No third data row", !reader.Read());
            Check("RowsRead counts data rows only", reader.RowsRead == 2);
        }
        finally
        {
            TryDelete(folder);
        }
    }

    // ---------------- Empty rows / missing identity ----------------

    /// <summary>
    /// The NorthWest case: the combined multi-sheet export stamps a "Source" value on every line,
    /// including the workbook's trailing blank rows. Those rows are not blank as text, so a raw
    /// all-cells-blank test lets them through and they load as all-NULL records - 145k of them on
    /// one NWL run. Emptiness must therefore be judged on the MAPPED columns.
    /// </summary>
    private static void EmptyRowsAreNotImported()
    {
        var folder = TempFolder();
        var csv = Path.Combine(folder, "line.csv");

        File.WriteAllText(csv,
            "Claim ID,Charge Amount,Source\r\n" +
            "C-1,37.00,Webpm\r\n" +
            ",,Webpm\r\n" +          // blank sheet row, Source stamped anyway
            "C-2,53.00,Daq\r\n" +
            ",,\r\n" +               // completely blank line
            "   ,  ,Daq\r\n",        // whitespace-only, Source stamped
            new UTF8Encoding(true));

        var fields = new List<FieldMapping>
        {
            new() { CsvHeader = "Claim ID",      SqlColumn = "ClaimID",      IncludeInHash = true },
            new() { CsvHeader = "Charge Amount", SqlColumn = "ChargeAmount", IncludeInHash = true }
        };

        var audit = new AuditColumns.AuditValues(1, "R1", "W1", "/sp", "line.csv",
            FileTypes.LineLevel, 23, "NorthWest");

        try
        {
            // "Source" is unmapped and NOT captured, so it must not keep a blank row alive.
            using (var reader = new CsvBulkDataReader(csv, fields, audit))
            {
                var rows = 0;
                while (reader.Read()) rows++;

                Check("Source-stamped blank rows are not imported", rows == 2, $"got {rows}");
                Check("RowsRead counts only real rows", reader.RowsRead == 2);
                Check("Blank rows are counted as skipped", reader.BlankRowsSkipped == 3,
                    $"got {reader.BlankRowsSkipped}");
            }

            // NWL actually MAPS Source to its own SQL column, which is the real production shape.
            // The stamp must still not keep a blank row alive.
            var mappedSource = new List<FieldMapping>(fields)
            {
                new() { CsvHeader = "Source", SqlColumn = "Source", IncludeInHash = true }
            };

            using (var withSource = new CsvBulkDataReader(csv, mappedSource, audit))
            {
                var rows = 0;
                while (withSource.Read()) rows++;

                Check("A mapped Source stamp does not make a blank row look populated", rows == 2,
                    $"got {rows}");
                Check("Blank rows are still skipped when Source is mapped",
                    withSource.BlankRowsSkipped == 3, $"got {withSource.BlankRowsSkipped}");
            }

            // The stamp is still stored on rows that do carry data.
            using (var withSource = new CsvBulkDataReader(csv, mappedSource, audit))
            {
                withSource.Read();
                Check("Source is still stored on a real row", (string?)withSource.GetValue(2) == "Webpm");
            }

            // Same rule when Source is unmapped and captured into AdditionalFields: still stored,
            // still not enough on its own to keep a blank row.
            using (var capturing = new CsvBulkDataReader(csv, fields, audit, captureAdditionalFields: true))
            {
                var rows = 0;
                while (capturing.Read()) rows++;

                Check("A captured Source stamp does not keep a blank row alive", rows == 2,
                    $"got {rows}");
                Check("Blank rows are still skipped when Source is captured",
                    capturing.BlankRowsSkipped == 3, $"got {capturing.BlankRowsSkipped}");
            }

            // A genuine unmapped column, by contrast, IS data and must keep its row.
            var withExtra = Path.Combine(folder, "extra.csv");
            File.WriteAllText(withExtra,
                "Claim ID,Charge Amount,Source,Note\r\n" +
                ",,Webpm,\r\n" +          // stamp only -> empty
                ",,Webpm,see me\r\n",     // real unmapped content -> keep
                new UTF8Encoding(true));

            using (var capturing = new CsvBulkDataReader(withExtra, fields, audit, captureAdditionalFields: true))
            {
                var rows = 0;
                while (capturing.Read()) rows++;

                Check("A row is kept when a real unmapped column has content", rows == 1, $"got {rows}");
                Check("The stamp-only row is skipped", capturing.BlankRowsSkipped == 1,
                    $"got {capturing.BlankRowsSkipped}");
            }
        }
        finally
        {
            TryDelete(folder);
        }
    }

    /// <summary>
    /// A row with real data but no ClaimID still loads - the data is real. It is counted so the
    /// loader can warn once, rather than dropping it or logging per row.
    /// </summary>
    private static void RowsWithoutIdentityAreImportedAndCounted()
    {
        var folder = TempFolder();
        var csv = Path.Combine(folder, "line.csv");

        File.WriteAllText(csv,
            "Claim ID,Charge Amount\r\n" +
            "C-1,37.00\r\n" +
            ",53.00\r\n" +   // no identity, but has a charge -> import + count
            ",\r\n" +        // empty -> skipped, never counted as missing identity
            "C-3,11.00\r\n",
            new UTF8Encoding(true));

        var fields = new List<FieldMapping>
        {
            new() { CsvHeader = "Claim ID",      SqlColumn = "ClaimID",      IncludeInHash = true },
            new() { CsvHeader = "Charge Amount", SqlColumn = "ChargeAmount", IncludeInHash = true }
        };

        var audit = new AuditColumns.AuditValues(1, "R1", "W1", "/sp", "line.csv",
            FileTypes.LineLevel, 23, "NorthWest");

        try
        {
            using var reader = new CsvBulkDataReader(csv, fields, audit);

            Check("ClaimID is recognised as an identity column",
                reader.IdentityColumns.Count == 1 && reader.IdentityColumns[0] == "ClaimID");

            var rows = 0;
            while (reader.Read()) rows++;

            Check("A row missing only its identity is still imported", rows == 3, $"got {rows}");
            Check("Rows missing identity are counted", reader.RowsMissingIdentity == 1,
                $"got {reader.RowsMissingIdentity}");
            Check("Empty rows are not counted as missing identity", reader.BlankRowsSkipped == 1);
            Check("A sample CSV line number is reported for the log",
                reader.MissingIdentitySampleLines.Count == 1 && reader.MissingIdentitySampleLines[0] == 3,
                $"got [{string.Join(",", reader.MissingIdentitySampleLines)}]");
        }
        finally
        {
            TryDelete(folder);
        }
    }

    // ---------------- AdditionalFields ----------------

    /// <summary>
    /// A lab adding columns to its file must not lose them, and must not change anything for a
    /// database that has not got the column yet.
    /// </summary>
    private static void AdditionalFieldsCaptureUnmappedColumns()
    {
        var folder = TempFolder();
        var csv = Path.Combine(folder, "line.csv");

        File.WriteAllText(csv,
            "Claim ID,Charge Amount,New Column A,New Column B\r\n" +
            "C-1,37.00,alpha,\r\n" +          // B empty - must be left out of the JSON
            "C-2,53.00,,\r\n",                // neither filled - the whole value must be NULL
            new UTF8Encoding(true));

        var fields = new List<FieldMapping>
        {
            new() { CsvHeader = "Claim ID",      SqlColumn = "ClaimID",      IncludeInHash = true },
            new() { CsvHeader = "Charge Amount", SqlColumn = "ChargeAmount", IncludeInHash = true }
        };

        var audit = new AuditColumns.AuditValues(1, "20260724R0044", "W1", "/sp/path", "line.csv",
            FileTypes.LineLevel, 20, "NorthWest");

        try
        {
            using (var off = new CsvBulkDataReader(csv, fields, audit))
            {
                Check("AdditionalFields off: column count is unchanged",
                    off.FieldCount == fields.Count + AuditColumns.Names.Count);
            }

            using var reader = new CsvBulkDataReader(csv, fields, audit, captureAdditionalFields: true);

            var additionalIndex = fields.Count + AuditColumns.Names.Count;

            Check("AdditionalFields on: one extra column is exposed",
                reader.FieldCount == additionalIndex + 1);
            Check("AdditionalFields is named to match the table",
                reader.GetName(additionalIndex) == AuditColumns.AdditionalFields);

            reader.Read();
            var json = (string?)reader.GetValue(additionalIndex);

            Check("Unmapped column value is captured",
                json != null && json.Contains("\"New Column A\":\"alpha\"", StringComparison.Ordinal));
            Check("Blank unmapped column is left out of the JSON",
                json != null && !json.Contains("New Column B", StringComparison.Ordinal));
            Check("Mapped columns still bind to their own SQL column",
                (string?)reader.GetValue(0) == "C-1");

            reader.Read();
            Check("A row with no extra values stores NULL, not '{}'", reader.IsDBNull(additionalIndex));
        }
        finally
        {
            TryDelete(folder);
        }
    }

    // ---------------- sensitive columns ----------------

    /// <summary>
    /// The SSN must never reach a row, however the lab spells the header. These assertions are the
    /// policy: if one fails, the pipeline is capturing something it must not.
    /// </summary>
    private static void SensitiveColumnsAreNeverCaptured()
    {
        foreach (var spelling in new[]
                 {
                     "SocialSecurityNumber", "Social Security Number", "social_security_number",
                     "SOCIAL SECURITY NO", "Patient Social Security #", "SSN", "ssn", "Patient SSN",
                     "SSN#", "Subscriber SSN"
                 })
        {
            Check($"blocked: '{spelling}'", SensitiveColumns.IsBlocked(spelling));
        }

        // Must not over-block: "ssn" appears inside these, and they are ordinary columns.
        foreach (var innocent in new[] { "ClassNumber", "Accession", "PatientName", "NPI", "Panel" })
            Check($"not blocked: '{innocent}'", !SensitiveColumns.IsBlocked(innocent));

        // End to end: an SSN column in the CSV must be absent from the JSON AND reported as excluded.
        var folder = TempFolder();
        var csv = Path.Combine(folder, "line.csv");

        File.WriteAllText(csv,
            "Claim ID,SocialSecurityNumber,New Column A\r\n" +
            "C-1,123-45-6789,alpha\r\n",
            new UTF8Encoding(true));

        var fields = new List<FieldMapping>
        {
            new() { CsvHeader = "Claim ID", SqlColumn = "ClaimID", IncludeInHash = true }
        };

        var audit = new AuditColumns.AuditValues(1, "20260804R0001", "W1", "/sp/path", "line.csv",
            FileTypes.LineLevel, 20, "NorthWest");

        try
        {
            using var reader = new CsvBulkDataReader(csv, fields, audit, captureAdditionalFields: true);
            var additionalIndex = fields.Count + AuditColumns.Names.Count;

            reader.Read();
            var json = (string?)reader.GetValue(additionalIndex);

            Check("SSN value is absent from the captured JSON",
                json != null && !json.Contains("123-45-6789", StringComparison.Ordinal));
            Check("SSN column name is absent from the captured JSON",
                json != null && !json.Contains("SocialSecurityNumber", StringComparison.Ordinal));
            Check("the other new column is still captured",
                json != null && json.Contains("New Column A", StringComparison.Ordinal));
            Check("the SSN column is reported as excluded",
                reader.ExcludedSensitiveHeaders.Count == 1 &&
                reader.ExcludedSensitiveHeaders[0] == "SocialSecurityNumber");
        }
        finally
        {
            TryDelete(folder);
        }
    }

    // ---------------- toggles ----------------

    private static void ToggleSkipReasons()
    {
        // Mirrors LineClaimImportService.ResolveSkipReason via observable behaviour of the toggles.
        var enabled = new LevelMapping { Enabled = true, CreateCsv = true, BulkCopyToTable = true, SqlTableName = "dbo.X" };
        // CreateCsv off, load on - the combination that must work. It used to be unreachable.
        var csvOff = new LevelMapping { Enabled = true, CreateCsv = false, BulkCopyToTable = true, SqlTableName = "dbo.X" };
        var levelOff = new LevelMapping { Enabled = false };

        Check("Defaults preserve current behaviour (BulkCopyToTable off)", new LevelMapping().BulkCopyToTable == false);
        Check("Defaults preserve current behaviour (CreateCsv on)", new LevelMapping().CreateCsv);
        Check("Defaults preserve current behaviour (Enabled on)", new LevelMapping().Enabled);
        Check("Enabled level is loadable", enabled is { Enabled: true, CreateCsv: true, BulkCopyToTable: true });
        Check("CreateCsv=false does NOT disable the bulk copy", csvOff.BulkCopyToTable);
        Check("Level toggles are independent", levelOff.Enabled == false && enabled.Enabled);
    }

    /// <summary>
    /// The CSV toggles publish a FILE; they must never decide whether rows reach SQL.
    /// The file is always produced in staging and the loader reads it from there, so
    /// CreateCsv=false means "no file on disk", never "no data in the table".
    /// </summary>
    /// <summary>
    /// Clinic Summary / Sales Rep Summary are marked from the two masters, so the rule that decides
    /// WHEN is the whole feature. Mirrors LineClaimImportService.MarkDerivedReportsAsync.
    /// </summary>
    private static void DerivedReportRules()
    {
        var clinic  = new DerivedReportOptions { ReportName = "Clinic Summary",    LabIds = new() };
        var salesRep = new DerivedReportOptions { ReportName = "Sales Rep Summary", LabIds = new() { 4, 16 } };

        // --- which labs produce which report ---
        Check("Clinic Summary applies to every lab", clinic.AppliesTo(4) && clinic.AppliesTo(20) && clinic.AppliesTo(18));
        Check("Sales Rep Summary applies to Cove (4)", salesRep.AppliesTo(4));
        Check("Sales Rep Summary applies to Elixir (16)", salesRep.AppliesTo(16));
        Check("Sales Rep Summary does NOT apply to Certus (18)", !salesRep.AppliesTo(18));
        Check("Sales Rep Summary does NOT apply to NorthWest (20)", !salesRep.AppliesTo(20));
        Check("A disabled derived report is filtered out",
            !new DerivedReportOptions { ReportName = "Clinic Summary", Enabled = false }.Enabled);

        // --- when the base counts as loaded ---
        static LineClaimImportOutcome Loaded(string t)  => new(t, Succeeded: true,  Skipped: false, 100, null);
        static LineClaimImportOutcome Skipped(string t) => new(t, Succeeded: true,  Skipped: true,    0, "off");
        static LineClaimImportOutcome Failed(string t)  => new(t, Succeeded: false, Skipped: false,   0, "boom");

        static bool Marks(params LineClaimImportOutcome[] results) =>
            results.All(r => r.Succeeded && !r.Skipped);

        Check("Both levels loaded -> mark",
            Marks(Loaded(FileTypes.LineLevel), Loaded(FileTypes.ClaimLevel)));
        Check("Line level failed -> do not mark",
            !Marks(Failed(FileTypes.LineLevel), Loaded(FileTypes.ClaimLevel)));
        Check("Claim level failed -> do not mark",
            !Marks(Loaded(FileTypes.LineLevel), Failed(FileTypes.ClaimLevel)));

        // A skip reports Succeeded = true, so checking only that would mark a green Clinic Summary
        // for a lab whose data never arrived. This is the assertion that catches it.
        Check("Claim level SKIPPED -> do not mark, even though it reports Succeeded",
            Skipped(FileTypes.ClaimLevel).Succeeded && !Marks(Loaded(FileTypes.LineLevel), Skipped(FileTypes.ClaimLevel)));
        Check("Both levels skipped -> do not mark",
            !Marks(Skipped(FileTypes.LineLevel), Skipped(FileTypes.ClaimLevel)));

        // --- the names must exist in ReportTypeMaster or the upsert rejects them ---
        Check("Clinic Summary name matches the master list",
            WorkflowReportNames.ClinicSummary == "Clinic Summary");
        Check("Sales Rep Summary name matches the master list",
            WorkflowReportNames.SalesRepSummary == "Sales Rep Summary");
    }

    /// <summary>
    /// Augustus PanelNew is taken from the source file's "Panel Category" column, not from the panel
    /// master workbook. Runs the real exporter over a real CSV for both levels.
    /// </summary>
    private static void AugustusPanelNewComesFromSourceColumn()
    {
        var folder = TempFolder();

        try
        {
            var source = Path.Combine(folder, "augustus_src.csv");
            File.WriteAllText(source,
                "Claim ID,Panel Name,Panel Category\r\n" +
                "C-1,STI Panel,Blood\r\n" +
                "C-2,Tox Screen,Toxicology\r\n" +
                "C-3,Unlisted,\r\n");

            var schema = new ColumnSchema
            {
                SchemaName = "test",
                HeaderRow = 1,
                Columns = new List<ColumnSpec> { new() { Name = "Claim ID" } }
            };

            // No panel master file at all - proves nothing is being read from one.
            foreach (var (level, isLineLevel) in new[] { ("line", true), ("claim", false) })
            {
                var outPath = Path.Combine(folder, $"out_{level}.csv");

                StandardCsvExporter.Generate(
                    sourceCsvPath: source,
                    headerRow: 1,
                    outputCsvPath: outPath,
                    commonSchema: schema,
                    labId: 24,
                    labName: "Augustus Labs",
                    sourceFileName: "augustus_src.csv",
                    ingestedOnLocal: DateTime.Now,
                    augmentation: StandardCsvExporter.BuildAugmentationContext("Augustus Labs", isLineLevel, null));

                var lines = File.ReadAllLines(outPath);
                var header = SplitCsv(lines[0]);
                var panelNew = Array.FindIndex(header, h => h.Equals("PanelNew", StringComparison.OrdinalIgnoreCase));

                Check($"[{level}] PanelNew column is emitted", panelNew >= 0);
                if (panelNew < 0) continue;

                Check($"[{level}] PanelNew takes the Panel Category value",
                    SplitCsv(lines[1])[panelNew] == "Blood");
                Check($"[{level}] PanelNew follows Panel Category row by row",
                    SplitCsv(lines[2])[panelNew] == "Toxicology");
                Check($"[{level}] Blank Panel Category gives a blank PanelNew",
                    SplitCsv(lines[3])[panelNew] == "");
            }

            // A file without the column must not fall back to a panel-name lookup.
            var noCategory = Path.Combine(folder, "no_category.csv");
            File.WriteAllText(noCategory, "Claim ID,Panel Name\r\nC-1,STI Panel\r\n");

            var noCatOut = Path.Combine(folder, "out_nocat.csv");
            StandardCsvExporter.Generate(
                sourceCsvPath: noCategory,
                headerRow: 1,
                outputCsvPath: noCatOut,
                commonSchema: schema,
                labId: 24,
                labName: "Augustus Labs",
                sourceFileName: "no_category.csv",
                ingestedOnLocal: DateTime.Now,
                augmentation: StandardCsvExporter.BuildAugmentationContext("Augustus Labs", true, null));

            var nlines = File.ReadAllLines(noCatOut);
            var nheader = SplitCsv(nlines[0]);
            var nIdx = Array.FindIndex(nheader, h => h.Equals("PanelNew", StringComparison.OrdinalIgnoreCase));

            Check("No Panel Category column -> PanelNew is blank, not a mapped guess",
                nIdx >= 0 && SplitCsv(nlines[1])[nIdx] == "");
        }
        finally
        {
            TryDelete(folder);
        }
    }

    /// <summary>Minimal CSV field splitter for the assertions above.</summary>
    private static string[] SplitCsv(string line)
    {
        var fields = new List<string>();
        var sb = new StringBuilder();
        bool quoted = false;

        for (int i = 0; i < line.Length; i++)
        {
            var c = line[i];

            if (quoted)
            {
                if (c == '"' && i + 1 < line.Length && line[i + 1] == '"') { sb.Append('"'); i++; }
                else if (c == '"') quoted = false;
                else sb.Append(c);
            }
            else if (c == '"') quoted = true;
            else if (c == ',') { fields.Add(sb.ToString()); sb.Clear(); }
            else sb.Append(c);
        }

        fields.Add(sb.ToString());
        return fields.ToArray();
    }

    private static void PerLevelCsvToggles()
    {
        // What the worker uses to decide whether to PUBLISH the csv.
        static bool Publishes(LevelMapping? level) => level is null || (level.Enabled && level.CreateCsv);

        var on   = new LevelMapping { Enabled = true,  CreateCsv = true,  BulkCopyToTable = true, SqlTableName = "dbo.X" };
        var off  = new LevelMapping { Enabled = true,  CreateCsv = false, BulkCopyToTable = true, SqlTableName = "dbo.X" };
        var dead = new LevelMapping { Enabled = false, CreateCsv = true,  BulkCopyToTable = true, SqlTableName = "dbo.X" };
        var noLoad = new LevelMapping { Enabled = true, CreateCsv = true, BulkCopyToTable = false };

        Check("both levels on -> both CSVs published", Publishes(on) && Publishes(on));
        Check("line on, claim off -> only line CSV published", Publishes(on) && !Publishes(off));
        Check("line off, claim on -> only claim CSV published", !Publishes(off) && Publishes(on));
        Check("both off -> no CSV published", !Publishes(off) && !Publishes(off));
        Check("absent level section defaults to publishing", Publishes(null));

        // The load decision, mirroring LineClaimImportService.ResolveSkipReason.
        static bool Loads(LevelMapping? level) => level is not null && level.Enabled && level.BulkCopyToTable;

        Check("CreateCsv=false STILL loads to SQL", Loads(off));
        Check("CreateCsv=true loads to SQL", Loads(on));
        Check("Enabled=false stops the load", !Loads(dead));
        Check("BulkCopyToTable=false stops the load", !Loads(noLoad));
        Check("publishing and loading are independent", Publishes(on) && Loads(off) && !Publishes(off));
    }

    // ---------------- helpers ----------------

    private static void Check(string name, bool condition, string? detail = null)
    {
        if (condition)
        {
            _passed++;
            Console.WriteLine("  ok   " + name);
        }
        else
        {
            Failures.Add(name + (detail is null ? "" : " (" + detail + ")"));
            Console.WriteLine("  FAIL " + name);
        }
    }

    private static string TempFolder()
    {
        var path = Path.Combine(Path.GetTempPath(), "lrn_selftest_" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }

    private static void TryDelete(string folder)
    {
        try { Directory.Delete(folder, recursive: true); } catch { /* best effort */ }
    }

    /// <summary>Minimal ILogger so the tests need no DI container or logging package.</summary>
    private sealed class NullLogger<T> : ILogger<T>
    {
        public static readonly NullLogger<T> Instance = new();
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => false;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception,
            Func<TState, Exception?, string> formatter) { }
    }
}
