using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Calls a per-lab CPT search SP on LRNMaster and maps all five result sets
/// into a <see cref="LabCptResult"/>.
/// Each SP (e.g. <c>dbo.usp_CPTCodeSearch_Augustus_LRN</c>) queries that lab's
/// database via cross-DB 3-part naming from LRNMaster.
/// </summary>
public sealed class SqlCptSearchRepository : ICptSearchRepository
{
    private readonly ILogger<SqlCptSearchRepository> _logger;

    public SqlCptSearchRepository(ILogger<SqlCptSearchRepository> logger)
        => _logger = logger;

    public async Task<LabCptResult> SearchAsync(
        string connectionString,
        string sprocName,
        string labName,
        string displayName,
        string cptCode,
        CancellationToken ct = default)
    {
        var panels       = new List<CptPanelSummary>();
        var denialCodes  = new List<CptDenialCode>();
        var monthlyTrend = new List<CptMonthlyTrend>();
        var claimLevel   = new List<CptClaimLevelRow>();
        var payers       = new List<CptPayerRow>();

        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);

            await using var cmd = new SqlCommand(sprocName, conn)
            {
                CommandType    = CommandType.StoredProcedure,
                CommandTimeout = 120,
            };
            cmd.Parameters.Add(new SqlParameter("@CPTCode", SqlDbType.NVarChar, 20)
            {
                Value = cptCode.Trim()
            });

            await using var reader = await cmd.ExecuteReaderAsync(ct);

            // ── RS 1 : Panel × ClaimStatus × DenialCode summary ─────────────
            while (await reader.ReadAsync(ct))
            {
                panels.Add(new CptPanelSummary
                {
                    PanelName     = reader.GetString(reader.GetOrdinal("PanelName")),
                    ClaimStatus   = reader.GetString(reader.GetOrdinal("ClaimStatus")),
                    DenialCode    = reader.GetString(reader.GetOrdinal("DenialCode")),
                    TotalLines    = reader.GetInt32(reader.GetOrdinal("LineCount")),
                    TotalUnits    = reader.GetDecimal(reader.GetOrdinal("TotalUnits")),
                    DeniedUnits   = reader.GetDecimal(reader.GetOrdinal("DeniedUnits")),
                    ClaimedUnits  = reader.GetDecimal(reader.GetOrdinal("ClaimedUnits")),
                    TotalPayments = reader.GetDecimal(reader.GetOrdinal("TotalPayments")),
                    TotalCharges  = reader.GetDecimal(reader.GetOrdinal("TotalCharges")),
                    EarliestDOS   = reader.GetString(reader.GetOrdinal("EarliestDOS")),
                    LatestDOS     = reader.GetString(reader.GetOrdinal("LatestDOS")),
                });
            }

            // ── RS 2 : Denial code breakdown ─────────────────────────────────
            await reader.NextResultAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                denialCodes.Add(new CptDenialCode
                {
                    DenialCode  = reader.GetString(reader.GetOrdinal("DenialCode")),
                    LineCount   = reader.GetInt32(reader.GetOrdinal("LineCount")),
                    DeniedUnits = reader.GetDecimal(reader.GetOrdinal("DeniedUnits")),
                    Payments    = reader.GetDecimal(reader.GetOrdinal("Payments")),
                });
            }

            // ── RS 3 : Monthly trend ─────────────────────────────────────────
            await reader.NextResultAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                monthlyTrend.Add(new CptMonthlyTrend
                {
                    MonthYear     = reader.GetString(reader.GetOrdinal("MonthYear")),
                    LineCount     = reader.GetInt32(reader.GetOrdinal("LineCount")),
                    TotalUnits    = reader.GetDecimal(reader.GetOrdinal("TotalUnits")),
                    DeniedUnits   = reader.GetDecimal(reader.GetOrdinal("DeniedUnits")),
                    ClaimedUnits  = reader.GetDecimal(reader.GetOrdinal("ClaimedUnits")),
                    TotalPayments = reader.GetDecimal(reader.GetOrdinal("TotalPayments")),
                });
            }

            // ── RS 4 : Claim-level summary ───────────────────────────────────
            await reader.NextResultAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                claimLevel.Add(new CptClaimLevelRow
                {
                    PanelName     = reader.GetString(reader.GetOrdinal("PanelName")),
                    ClaimStatus   = reader.GetString(reader.GetOrdinal("ClaimStatus")),
                    DenialCode    = reader.GetString(reader.GetOrdinal("DenialCode")),
                    ClaimCount    = reader.GetInt32(reader.GetOrdinal("ClaimCount")),
                    TotalPayments = reader.GetDecimal(reader.GetOrdinal("TotalPayments")),
                    TotalCharges  = reader.GetDecimal(reader.GetOrdinal("TotalCharges")),
                });
            }

            // ── RS 5 : Payer breakdown ───────────────────────────────────────
            await reader.NextResultAsync(ct);
            while (await reader.ReadAsync(ct))
            {
                payers.Add(new CptPayerRow
                {
                    PayerName     = reader.GetString(reader.GetOrdinal("PayerName")),
                    PayerType     = reader.GetString(reader.GetOrdinal("PayerType")),
                    LineCount     = reader.GetInt32(reader.GetOrdinal("LineCount")),
                    TotalUnits    = reader.GetDecimal(reader.GetOrdinal("TotalUnits")),
                    DeniedUnits   = reader.GetDecimal(reader.GetOrdinal("DeniedUnits")),
                    TotalPayments = reader.GetDecimal(reader.GetOrdinal("TotalPayments")),
                });
            }

            _logger.LogInformation(
                "CPTSearch: sp={SP} cpt={Cpt} panels={P} denials={D} trend={T} claims={C}",
                sprocName, cptCode, panels.Count, denialCodes.Count,
                monthlyTrend.Count, claimLevel.Count);

            return new LabCptResult
            {
                LabName      = labName,
                DisplayName  = displayName,
                HasData      = panels.Count > 0 || claimLevel.Count > 0,
                Panels       = panels,
                DenialCodes  = denialCodes,
                MonthlyTrend = monthlyTrend,
                ClaimLevel   = claimLevel,
                Payers       = payers,
            };
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex,
                "CPTSearch: sp={SP} cpt={Cpt} failed — {Msg}",
                sprocName, cptCode, ex.Message);

            return new LabCptResult
            {
                LabName      = labName,
                DisplayName  = displayName,
                HasData      = false,
                ErrorMessage = $"[{sprocName}] {ex.Message}",
            };
        }
    }

    // ── GetActiveLabsAsync ────────────────────────────────────────────────────
    // Reads dbo.LabRegistry on LRNMaster — single source of truth for CPT search.
    // No lab config JSON files are involved.

    public async Task<List<CptLabEntry>> GetActiveLabsAsync(
        string connectionString,
        CancellationToken ct = default)
    {
        const string sql = """
            SELECT LabName, DisplayName, SprocName
            FROM   dbo.LabRegistry
            WHERE  IsActive  = 1
              AND  SprocName IS NOT NULL
              AND  LTRIM(RTRIM(SprocName)) <> ''
            ORDER  BY SortOrder, DisplayName;
            """;

        var labs = new List<CptLabEntry>();
        try
        {
            await using var conn = new SqlConnection(connectionString);
            await conn.OpenAsync(ct);
            await using var cmd  = new SqlCommand(sql, conn) { CommandTimeout = 15 };
            await using var r    = await cmd.ExecuteReaderAsync(ct);
            while (await r.ReadAsync(ct))
            {
                labs.Add(new CptLabEntry
                {
                    LabName     = r.GetString(r.GetOrdinal("LabName")),
                    DisplayName = r.GetString(r.GetOrdinal("DisplayName")),
                    SprocName   = r.GetString(r.GetOrdinal("SprocName")),
                });
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex,
                "CPTSearch: failed to read dbo.LabRegistry — {Msg}", ex.Message);
        }
        return labs;
    }
}
