using LRN.PayerPolicyMapper.Core.Abstractions;
using Microsoft.Data.SqlClient;

namespace LRN.PayerPolicyMapper.Core.Data;

/// <summary>Loads the Step 0 reference data from LRNMaster (same raw ADO.NET style as the rest of the solution).</summary>
public sealed class SqlReferenceDataRepository : IReferenceDataRepository
{
    private readonly string _connectionString;

    public SqlReferenceDataRepository(string connectionString) => _connectionString = connectionString;

    public async Task<ReferenceDataSet> LoadAsync(CancellationToken ct)
    {
        var data = new ReferenceDataSet();
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);

        await using (var cmd = new SqlCommand("SELECT StateCode, StateName FROM dbo.USStateCode WHERE IsActive = 1;", conn))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                data.States.Add(new UsState(r.GetString(0).Trim(), r.GetString(1)));

        await using (var cmd = new SqlCommand("SELECT Code FROM dbo.PlanNetworkTypeCode WHERE IsActive = 1;", conn))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                data.PlanNetworkTypeCodes.Add(r.GetString(0));

        await using (var cmd = new SqlCommand("SELECT MappingId, BrandKeyword, StateCode FROM dbo.StateBrandMapping WHERE IsActive = 1 ORDER BY MappingId;", conn))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                data.StateBrandMappings.Add(new StateBrandMappingRow(r.GetInt32(0), r.GetString(1), r.IsDBNull(2) ? null : r.GetString(2).Trim()));

        await using (var cmd = new SqlCommand("SELECT RuleId, ProgramType, Pattern, Priority FROM dbo.ProgramTypeRule WHERE IsActive = 1 ORDER BY Priority, RuleId;", conn))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                data.ProgramTypeRules.Add(new ProgramTypeRuleRow(r.GetInt32(0), r.GetString(1), r.IsDBNull(2) ? null : r.GetString(2), r.GetInt32(3)));

        await using (var cmd = new SqlCommand("SELECT RuleId, Family, Pattern, Priority FROM dbo.PayerFamilyRule WHERE IsActive = 1 ORDER BY Priority, RuleId;", conn))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                data.PayerFamilyRules.Add(new PayerFamilyRuleRow(r.GetInt32(0), r.GetString(1), r.GetString(2), r.GetInt32(3)));

        await using (var cmd = new SqlCommand("SELECT CanonicalName, ResolvedStateCode, GlobalPayerId FROM dbo.PayerAlias;", conn))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                data.Aliases.Add(new PayerAliasRow(r.GetString(0), r.IsDBNull(1) ? null : r.GetString(1).Trim(), r.GetInt32(2)));

        // Active policy rows only. IsActive is a free-text flag, so mirror the app's own convention:
        // only an explicit inactive marker excludes a row - blank/unknown counts as active. An
        // allow-list here ("Y"/"ACTIVE"/...) silently empties the whole index when an environment
        // stores an unanticipated spelling, which kills suggestions and search everywhere.
        await using (var cmd = new SqlCommand("""
            SELECT PPInsuranceMasterId, TRY_CONVERT(INT, GlobalPayerId) AS GlobalPayerIdInt,
                   PayerNameRaw, PayerNameNormalized, PayerFamily, PlanType, PayerState,
                   GlobalPayerCode, PayerGroupCode, BenefitAdminCode, BenefitAdministrator
            FROM dbo.PayerPolicyInsuranceMaster
            WHERE NULLIF(LTRIM(RTRIM(PayerNameRaw)), '') IS NOT NULL
              AND (IsActive IS NULL
                   OR UPPER(LTRIM(RTRIM(IsActive))) NOT IN ('N', 'NO', '0', 'FALSE', 'INACTIVE'));
            """, conn))
        await using (var r = await cmd.ExecuteReaderAsync(ct))
            while (await r.ReadAsync(ct))
                data.PolicyRecords.Add(new PayerPolicyRecord
                {
                    PPInsuranceMasterId = r.GetInt32(0),
                    GlobalPayerId = r.IsDBNull(1) ? null : r.GetInt32(1),
                    PayerNameRaw = r.GetString(2),
                    PayerNameNormalized = r.IsDBNull(3) ? null : r.GetString(3),
                    PayerFamily = r.IsDBNull(4) ? null : r.GetString(4),
                    PlanType = r.IsDBNull(5) ? null : r.GetString(5),
                    PayerState = r.IsDBNull(6) ? null : r.GetString(6),
                    GlobalPayerCode = r.IsDBNull(7) ? null : r.GetString(7),
                    PayerGroupCode = r.IsDBNull(8) ? null : r.GetInt32(8),
                    BenefitAdminCode = r.IsDBNull(9) ? null : r.GetString(9),
                    BenefitAdministrator = r.IsDBNull(10) ? null : r.GetString(10)
                });

        return data;
    }

    public async Task<string> GetRulesVersionAsync(CancellationToken ct)
    {
        // Per-table BINARY_CHECKSUM aggregates so ANY in-place column edit (e.g. changing a rule's
        // Pattern from the rules admin screen) changes the version. The earlier count+MAX(CreatedDate)
        // scheme missed pure updates because those change neither the row count nor CreatedDate.
        // USStateCode is included for the same reason (state edits feed Step 2 resolution).
        const string sql = """
            SELECT CONCAT(
                'pp:',  (SELECT CONCAT(COUNT(1), '|', CONVERT(VARCHAR(33), MAX(x.d), 126)) FROM (SELECT CreatedOn AS d FROM dbo.PayerPolicyInsuranceMaster UNION ALL SELECT ModifiedOn FROM dbo.PayerPolicyInsuranceMaster) x),
                ';fam:', (SELECT CONCAT(COUNT(1), '|', ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(RuleId, Family, Pattern, Priority, IsActive)), 0)) FROM dbo.PayerFamilyRule),
                ';sbm:', (SELECT CONCAT(COUNT(1), '|', ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(MappingId, BrandKeyword, StateCode, IsActive)), 0)) FROM dbo.StateBrandMapping),
                ';ptr:', (SELECT CONCAT(COUNT(1), '|', ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(RuleId, ProgramType, Pattern, Priority, IsActive)), 0)) FROM dbo.ProgramTypeRule),
                ';pnt:', (SELECT CONCAT(COUNT(1), '|', ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(CodeId, Code, IsActive)), 0)) FROM dbo.PlanNetworkTypeCode),
                ';usc:', (SELECT CONCAT(COUNT(1), '|', ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(StateCode, StateName, IsActive)), 0)) FROM dbo.USStateCode),
                ';ali:', (SELECT CONCAT(COUNT(1), '|', CONVERT(VARCHAR(33), MAX(ConfirmedDate), 126)) FROM dbo.PayerAlias));
            """;
        await using var conn = new SqlConnection(_connectionString);
        await conn.OpenAsync(ct);
        await using var cmd = new SqlCommand(sql, conn);
        return (string)(await cmd.ExecuteScalarAsync(ct) ?? string.Empty);
    }
}
