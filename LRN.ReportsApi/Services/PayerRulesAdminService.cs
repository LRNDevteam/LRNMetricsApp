using System.Text.Json;
using System.Text.RegularExpressions;
using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

/// <summary>
/// Single-page admin CRUD over the payer-mapper rule tables (Payer Family, State Brand Mapping,
/// Program Type, Product Line, Plan Network Codes, US State Codes). All SQL is generated from the
/// hardcoded registry below - table/column names never come from the request - and every mutation
/// asks the matching-pipeline index provider to rebuild so rule edits take effect immediately.
/// </summary>
public interface IPayerRulesAdminService
{
    IReadOnlyList<RuleTableMetadata> GetTables();
    Task<IReadOnlyList<Dictionary<string, object?>>> ListAsync(string tableKey, CancellationToken ct);
    Task<(string Id, bool IndexRebuilt)> CreateAsync(string tableKey, Dictionary<string, JsonElement> values, string userName, CancellationToken ct);
    Task<bool> UpdateAsync(string tableKey, string id, Dictionary<string, JsonElement> values, string userName, CancellationToken ct);
    Task<bool> SetActiveAsync(string tableKey, string id, bool isActive, string userName, CancellationToken ct);
    Task<bool> RebuildIndexAsync(CancellationToken ct);
}

/// <summary>Column kinds drive both validation here and the input control the admin page renders.</summary>
public sealed record RuleColumnMetadata(string Name, string Label, string Kind, bool Required, int MaxLength, bool ReadOnlyOnEdit = false);

public sealed record RuleTableMetadata(string Key, string Title, string Description, string IdColumn, IReadOnlyList<RuleColumnMetadata> Columns);

public sealed class PayerRulesAdminService : IPayerRulesAdminService
{
    private sealed record TableDef(
        string Key,
        string Title,
        string Description,
        string Table,
        string IdColumn,
        bool IdentityId,
        bool HasAudit,
        string OrderBy,
        IReadOnlyList<RuleColumnMetadata> Columns);

    // Kind values: text | int | bool-free (not used yet) | state (FK to USStateCode) | regex (must compile)
    private static readonly TableDef[] Tables =
    {
        new("payer-family", "Payer Family Rules",
            "Groups payer name variants under a parent family. Lower priority evaluates first (10 sub-brands, 50 standard, 900 catch-alls).",
            "dbo.PayerFamilyRule", "RuleId", IdentityId: true, HasAudit: true, OrderBy: "Priority, Family",
            new RuleColumnMetadata[]
            {
                new("Family", "Family", "text", Required: true, MaxLength: 100),
                new("Pattern", "Pattern (regex alternation)", "regex", Required: true, MaxLength: 400),
                new("DefaultEntityType", "Default Entity Type", "text", Required: false, MaxLength: 50),
                new("Priority", "Priority", "int", Required: true, MaxLength: 0),
                new("Notes", "Notes", "text", Required: false, MaxLength: 500)
            }),
        new("state-brand", "State Brand Mapping",
            "Maps a brand keyword to its known home state. Leave the state blank when it must come from the raw name or manual review.",
            "dbo.StateBrandMapping", "MappingId", IdentityId: true, HasAudit: true, OrderBy: "BrandKeyword",
            new RuleColumnMetadata[]
            {
                new("BrandKeyword", "Brand Keyword", "text", Required: true, MaxLength: 100),
                new("StateCode", "State", "state", Required: false, MaxLength: 2),
                new("NormalizedBrandName", "Normalized Brand Name", "text", Required: false, MaxLength: 200),
                new("Notes", "Notes", "text", Required: false, MaxLength: 500)
            }),
        new("program-type", "Program Type Rules",
            "Classifies Medicare / Medicaid / Commercial / Exchange / Federal / Dual. Lower priority evaluates first; the Commercial fallback row intentionally has no pattern.",
            "dbo.ProgramTypeRule", "RuleId", IdentityId: false, HasAudit: true, OrderBy: "Priority, RuleId",
            new RuleColumnMetadata[]
            {
                new("ProgramType", "Program Type", "text", Required: true, MaxLength: 50),
                new("Pattern", "Pattern (regex alternation)", "regex", Required: false, MaxLength: 400),
                new("Priority", "Priority", "int", Required: true, MaxLength: 0),
                new("Notes", "Notes", "text", Required: false, MaxLength: 500)
            }),
        new("product-line", "Product Line Rules",
            "Product-line keywords with program/entity overrides. Plan-type-only tokens (HMO/PPO/...) have no overrides and are stripped in Step 1B.",
            "dbo.ProductLineRule", "RuleId", IdentityId: true, HasAudit: true, OrderBy: "ProductCode",
            new RuleColumnMetadata[]
            {
                new("ProductCode", "Product Code", "text", Required: true, MaxLength: 50),
                new("Pattern", "Pattern (regex alternation)", "regex", Required: true, MaxLength: 400),
                new("ProgramOverride", "Program Override", "text", Required: false, MaxLength: 50),
                new("EntityOverride", "Entity Override", "text", Required: false, MaxLength: 50),
                new("Notes", "Notes", "text", Required: false, MaxLength: 500)
            }),
        new("plan-network", "Plan Network Type Codes",
            "Network/plan-type codes stripped from raw payer names in Step 1B (PPO, HMO, POS II, ...). Marketing names like Choice/Select belong in Payer Alias, not here.",
            "dbo.PlanNetworkTypeCode", "CodeId", IdentityId: true, HasAudit: false, OrderBy: "Code",
            new RuleColumnMetadata[]
            {
                new("Code", "Code", "text", Required: true, MaxLength: 20),
                new("Notes", "Notes", "text", Required: false, MaxLength: 500)
            }),
        new("us-state", "US State Codes",
            "US state & territory lookup referenced by the state-resolution rules. The two-letter code is the primary key and cannot change after creation.",
            "dbo.USStateCode", "StateCode", IdentityId: false, HasAudit: false, OrderBy: "StateCode",
            new RuleColumnMetadata[]
            {
                new("StateCode", "State Code", "text", Required: true, MaxLength: 2, ReadOnlyOnEdit: true),
                new("StateName", "State Name", "text", Required: true, MaxLength: 100)
            })
    };

    private readonly string _connectionString;
    private readonly IPayerPolicyIndexProvider _indexProvider;
    private readonly ILogger<PayerRulesAdminService> _logger;

    public PayerRulesAdminService(IConfiguration configuration, IPayerPolicyIndexProvider indexProvider, ILogger<PayerRulesAdminService> logger)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection")
            ?? throw new InvalidOperationException("ConnectionStrings:DefaultConnection is missing. It must point to LRNMaster.");
        _indexProvider = indexProvider;
        _logger = logger;
    }

    public IReadOnlyList<RuleTableMetadata> GetTables()
        => Tables.Select(t => new RuleTableMetadata(t.Key, t.Title, t.Description, t.IdColumn, t.Columns)).ToList();

    private static TableDef Resolve(string tableKey)
        => Tables.FirstOrDefault(t => string.Equals(t.Key, tableKey, StringComparison.OrdinalIgnoreCase))
           ?? throw new ArgumentException($"Unknown rule table '{tableKey}'.");

    public async Task<IReadOnlyList<Dictionary<string, object?>>> ListAsync(string tableKey, CancellationToken ct)
    {
        var def = Resolve(tableKey);
        var auditCols = def.HasAudit ? ", CreatedBy, CreatedDate" : string.Empty;
        var sql = $"SELECT {def.IdColumn}, {string.Join(", ", def.Columns.Select(c => c.Name).Where(c => c != def.IdColumn))}, IsActive{auditCols} FROM {def.Table} ORDER BY {def.OrderBy};";
        var rows = new List<Dictionary<string, object?>>();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        await using var rd = await cmd.ExecuteReaderAsync(ct);
        while (await rd.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);
            for (var i = 0; i < rd.FieldCount; i++)
            {
                var value = rd.IsDBNull(i) ? null : rd.GetValue(i);
                row[rd.GetName(i)] = value switch
                {
                    string s => s.Trim(),
                    bool b => b,
                    DateTime d => d.ToString("yyyy-MM-dd HH:mm"),
                    _ => value
                };
            }
            rows.Add(row);
        }
        return rows;
    }

    public async Task<(string Id, bool IndexRebuilt)> CreateAsync(string tableKey, Dictionary<string, JsonElement> values, string userName, CancellationToken ct)
    {
        var def = Resolve(tableKey);
        var data = ValidateAndConvert(def, values, isCreate: true);

        var insertCols = new List<string>(data.Keys);
        var insertParams = insertCols.Select(c => "@c_" + c).ToList();
        insertCols.Add("IsActive"); insertParams.Add("1");
        if (def.HasAudit)
        {
            insertCols.Add("CreatedBy"); insertParams.Add("@CreatedBy");
            insertCols.Add("CreatedDate"); insertParams.Add("GETDATE()");
        }

        string sql;
        if (def.IdentityId)
        {
            sql = $"INSERT INTO {def.Table} ({string.Join(", ", insertCols)}) OUTPUT INSERTED.{def.IdColumn} VALUES ({string.Join(", ", insertParams)});";
        }
        else if (string.Equals(def.Key, "us-state", StringComparison.OrdinalIgnoreCase))
        {
            // StateCode is the natural PK and is one of the converted values already.
            sql = $"INSERT INTO {def.Table} ({string.Join(", ", insertCols)}) OUTPUT INSERTED.{def.IdColumn} VALUES ({string.Join(", ", insertParams)});";
        }
        else
        {
            // ProgramTypeRule.RuleId is a plain (non-identity) int PK - mint MAX+1 in the same statement.
            insertCols.Insert(0, def.IdColumn);
            insertParams.Insert(0, $"(SELECT ISNULL(MAX({def.IdColumn}), 0) + 1 FROM {def.Table} WITH (TABLOCKX, HOLDLOCK))");
            sql = $"INSERT INTO {def.Table} ({string.Join(", ", insertCols)}) OUTPUT INSERTED.{def.IdColumn} VALUES ({string.Join(", ", insertParams)});";
        }

        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        AddValueParams(cmd, data);
        if (def.HasAudit) cmd.Parameters.AddWithValue("@CreatedBy", string.IsNullOrWhiteSpace(userName) ? "RulesAdmin" : userName);
        object? newId;
        try { newId = await cmd.ExecuteScalarAsync(ct); }
        catch (SqlException ex) when (ex.Number is 2601 or 2627) { throw new ArgumentException(DuplicateMessage(def)); }
        catch (SqlException ex) when (ex.Number == 547) { throw new ArgumentException("The selected state code does not exist in US State Codes."); }

        var rebuilt = await TryRebuildIndexAsync(ct);
        return (Convert.ToString(newId) ?? string.Empty, rebuilt);
    }

    public async Task<bool> UpdateAsync(string tableKey, string id, Dictionary<string, JsonElement> values, string userName, CancellationToken ct)
    {
        var def = Resolve(tableKey);
        var data = ValidateAndConvert(def, values, isCreate: false);
        if (data.Count == 0) throw new ArgumentException("No editable values were provided.");

        var sets = string.Join(", ", data.Keys.Select(c => $"{c} = @c_{c}"));
        var sql = $"UPDATE {def.Table} SET {sets} WHERE {def.IdColumn} = @Id;";
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        AddValueParams(cmd, data);
        cmd.Parameters.AddWithValue("@Id", ConvertId(def, id));
        int affected;
        try { affected = await cmd.ExecuteNonQueryAsync(ct); }
        catch (SqlException ex) when (ex.Number is 2601 or 2627) { throw new ArgumentException(DuplicateMessage(def)); }
        catch (SqlException ex) when (ex.Number == 547) { throw new ArgumentException("The selected state code does not exist in US State Codes."); }

        if (affected > 0) await TryRebuildIndexAsync(ct);
        return affected > 0;
    }

    public async Task<bool> SetActiveAsync(string tableKey, string id, bool isActive, string userName, CancellationToken ct)
    {
        var def = Resolve(tableKey);
        var sql = $"UPDATE {def.Table} SET IsActive = @Active WHERE {def.IdColumn} = @Id;";
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        cmd.Parameters.AddWithValue("@Active", isActive);
        cmd.Parameters.AddWithValue("@Id", ConvertId(def, id));
        var affected = await cmd.ExecuteNonQueryAsync(ct);
        if (affected > 0) await TryRebuildIndexAsync(ct);
        return affected > 0;
    }

    public async Task<bool> RebuildIndexAsync(CancellationToken ct)
    {
        var (_, rebuilt) = await _indexProvider.RefreshIfChangedAsync(ct);
        return rebuilt;
    }

    private async Task<bool> TryRebuildIndexAsync(CancellationToken ct)
    {
        try
        {
            var (_, rebuilt) = await _indexProvider.RefreshIfChangedAsync(ct);
            return rebuilt;
        }
        catch (Exception ex)
        {
            // The save itself succeeded; a failed rebuild only delays the effect until the next
            // TTL check, so report-and-continue instead of failing the request.
            _logger.LogError(ex, "Payer rules saved but the matching index rebuild failed; it will retry on the next TTL check.");
            return false;
        }
    }

    private static object ConvertId(TableDef def, string id)
    {
        if (string.Equals(def.Key, "us-state", StringComparison.OrdinalIgnoreCase))
        {
            var code = (id ?? string.Empty).Trim().ToUpperInvariant();
            if (code.Length != 2) throw new ArgumentException("State code must be exactly 2 letters.");
            return code;
        }
        return int.TryParse(id, out var n) ? n : throw new ArgumentException("Invalid record id.");
    }

    private static string DuplicateMessage(TableDef def) => def.Key switch
    {
        "state-brand" => "That Brand Keyword already exists.",
        "product-line" => "That Product Code already exists.",
        "plan-network" => "That Code already exists.",
        "us-state" => "That State Code already exists.",
        _ => "A record with the same unique value already exists."
    };

    /// <summary>Converts the posted JSON values into SQL parameters, enforcing the registry's rules.</summary>
    private static Dictionary<string, object> ValidateAndConvert(TableDef def, Dictionary<string, JsonElement> values, bool isCreate)
    {
        var lookup = new Dictionary<string, JsonElement>(values, StringComparer.OrdinalIgnoreCase);
        var data = new Dictionary<string, object>();
        foreach (var col in def.Columns)
        {
            if (!isCreate && col.ReadOnlyOnEdit) continue;

            lookup.TryGetValue(col.Name, out var element);
            var raw = element.ValueKind switch
            {
                JsonValueKind.String => element.GetString(),
                JsonValueKind.Number => element.GetRawText(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => null
            };
            raw = raw?.Trim();

            if (string.IsNullOrEmpty(raw))
            {
                if (col.Required) throw new ArgumentException($"{col.Label} is required.");
                data[col.Name] = DBNull.Value;
                continue;
            }

            switch (col.Kind)
            {
                case "int":
                    if (!int.TryParse(raw, out var number)) throw new ArgumentException($"{col.Label} must be a whole number.");
                    data[col.Name] = number;
                    break;
                case "state":
                    var code = raw.ToUpperInvariant();
                    if (code.Length != 2 || !code.All(char.IsLetter)) throw new ArgumentException($"{col.Label} must be a 2-letter state code.");
                    data[col.Name] = code;
                    break;
                case "regex":
                    if (col.MaxLength > 0 && raw.Length > col.MaxLength) throw new ArgumentException($"{col.Label} exceeds {col.MaxLength} characters.");
                    try { _ = new Regex(raw, RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1)); }
                    catch (ArgumentException ex) { throw new ArgumentException($"{col.Label} is not a valid regular expression: {ex.Message}"); }
                    data[col.Name] = raw;
                    break;
                default:
                    if (col.MaxLength > 0 && raw.Length > col.MaxLength) throw new ArgumentException($"{col.Label} exceeds {col.MaxLength} characters.");
                    if (string.Equals(def.Key, "us-state", StringComparison.OrdinalIgnoreCase) && string.Equals(col.Name, "StateCode", StringComparison.OrdinalIgnoreCase))
                    {
                        var state = raw.ToUpperInvariant();
                        if (state.Length != 2 || !state.All(char.IsLetter)) throw new ArgumentException("State Code must be exactly 2 letters.");
                        raw = state;
                    }
                    data[col.Name] = raw;
                    break;
            }
        }
        return data;
    }

    private static void AddValueParams(SqlCommand cmd, Dictionary<string, object> data)
    {
        foreach (var (name, value) in data)
            cmd.Parameters.AddWithValue("@c_" + name, value);
    }
}
