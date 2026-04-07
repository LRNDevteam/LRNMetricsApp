using System.Data;
using Microsoft.Data.SqlClient;
using CaptureDataApp.Models;

namespace CaptureDataApp.Services;

/// <summary>
/// Persists CodingValidation rows and the Financial Summary to SQL Server
/// using TVP bulk insert and the stored procedures created in 01_CreateTables.sql.
/// </summary>
public sealed class CodingDbService
{
    private readonly string _connectionString;

    public CodingDbService(string connectionString)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);
        _connectionString = connectionString;
    }

    // ?? Public API ????????????????????????????????????????????????????????????

    /// <summary>
    /// Returns the <c>SourceFilePath</c> that is currently loaded in
    /// <c>CodingValidation</c> for <paramref name="labName"/>, or <c>null</c>
    /// when no rows exist yet.  Used to skip processing when the file on disk
    /// matches what is already live in the table.
    /// </summary>
    public string? GetLatestSourceFilePath(string labName)
    {
        using var conn = new SqlConnection(_connectionString);
        conn.Open();
        using var cmd = new SqlCommand(
            """
            SELECT TOP 1 SourceFilePath
            FROM   dbo.CodingValidation
            WHERE  LabName = @LabName
            ORDER  BY InsertedDateTime DESC
            """, conn);
        cmd.Parameters.AddWithValue("@LabName", labName);
        var result = cmd.ExecuteScalar();
        return result is DBNull or null ? null : (string)result;
    }

    /// <summary>
    /// Bulk-inserts all detail rows for a lab/week via the stored procedure.
    /// The SP skips silently if <c>SourceFilePath</c> is already present in
    /// <c>CodingValidation</c> for this lab, archives all prior rows into
    /// <c>CodingValidationData</c>, then inserts the new file's rows.
    /// Returns the number of rows inserted (0 = skipped).
    /// </summary>
    public int InsertDetailRows(List<CodingValidationRow> rows, string labName, string weekFolder)
    {
        if (rows.Count == 0) return 0;

        var sourceFilePath = rows[0].SourceFilePath;
        var runId          = rows[0].FileLogId;           // short prefix: "20260316R0215"
        var fileName       = Path.GetFileName(sourceFilePath);
        var fileCreated    = File.Exists(sourceFilePath)
                             ? (object)File.GetCreationTime(sourceFilePath)
                             : DBNull.Value;

        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        using var cmd = new SqlCommand("dbo.usp_BulkInsertCodingValidation", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 300
        };

        var tvp = BuildTvp(rows);
        cmd.Parameters.Add(new SqlParameter("@Rows", SqlDbType.Structured)
        {
            TypeName = "dbo.CodingValidationTVP",
            Value    = tvp,
        });
        cmd.Parameters.AddWithValue("@LabName",        labName);
        cmd.Parameters.AddWithValue("@WeekFolder",     weekFolder);
        cmd.Parameters.AddWithValue("@SourceFilePath", sourceFilePath);
        cmd.Parameters.AddWithValue("@RunId",          runId);
        cmd.Parameters.AddWithValue("@FileName",       fileName);
        cmd.Parameters.Add(new SqlParameter("@FileCreatedDateTime", SqlDbType.DateTime)
        {
            Value = fileCreated
        });

        var result = cmd.ExecuteScalar();
        return result is int count ? count : 0;
    }

    /// <summary>
    /// Upserts the financial summary row for a lab/week.
    /// Skips silently if the exact same SourceFilePath is already stored,
    /// meaning the file has already been processed in a previous run.
    /// Returns true when a row was inserted or updated, false when skipped.
    /// </summary>
    public bool UpsertFinancialSummary(CodingFinancialSummary s)
    {
        using var conn = new SqlConnection(_connectionString);
        conn.Open();

        // Guard: skip if this exact source file was already loaded for this lab/week.
        using (var chk = new SqlCommand(
            """
            SELECT COUNT(1) FROM dbo.CodingFinancialSummary
            WHERE LabName = @LabName AND WeekFolder = @WeekFolder
              AND SourceFilePath = @SourceFilePath
            """, conn))
        {
            chk.Parameters.AddWithValue("@LabName",       s.LabName);
            chk.Parameters.AddWithValue("@WeekFolder",    s.WeekFolder);
            chk.Parameters.AddWithValue("@SourceFilePath", s.SourceFilePath);
            if ((int)chk.ExecuteScalar()! > 0)
                return false;   // already loaded — nothing to do
        }

        using var cmd = new SqlCommand("dbo.usp_UpsertCodingFinancialSummary", conn)
        {
            CommandType    = CommandType.StoredProcedure,
            CommandTimeout = 60
        };

        cmd.Parameters.AddWithValue("@LabName",                           s.LabName);
        cmd.Parameters.AddWithValue("@WeekFolder",                        s.WeekFolder);
        cmd.Parameters.AddWithValue("@SourceFilePath",                    s.SourceFilePath);
        cmd.Parameters.AddWithValue("@ReportDate",                        s.ReportDate);
        cmd.Parameters.AddWithValue("@TotalClaims",                       (object?)s.TotalClaims ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@TotalBilledCharges",                (object?)s.TotalBilledCharges ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ExpectedBilledCharges",             (object?)s.ExpectedBilledCharges ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueImpact_Claims",              (object?)s.RevenueImpact_Claims ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueImpact_ActualBilled",        (object?)s.RevenueImpact_ActualBilled ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueImpact_PotentialLoss",       (object?)s.RevenueImpact_PotentialLoss ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueImpact_ExpectedRecoup",      (object?)s.RevenueImpact_ExpectedRecoup ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueLoss_Claims",                (object?)s.RevenueLoss_Claims ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueLoss_ActualBilled",          (object?)s.RevenueLoss_ActualBilled ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueLoss_PotentialLoss",         (object?)s.RevenueLoss_PotentialLoss ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueAtRisk_Claims",              (object?)s.RevenueAtRisk_Claims ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueAtRisk_ActualBilled",        (object?)s.RevenueAtRisk_ActualBilled ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@RevenueAtRisk_PotentialRecoup",     (object?)s.RevenueAtRisk_PotentialRecoup ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Compliance_TotalClaims",            (object?)s.Compliance_TotalClaims ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@Compliance_ClaimsWithIssues",       (object?)s.Compliance_ClaimsWithIssues ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ComplianceRate",                    s.ComplianceRate);
        cmd.Parameters.AddWithValue("@ClaimsWithMissingCPTs",             (object?)s.ClaimsWithMissingCPTs ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ClaimsWithAdditionalCPTs",          (object?)s.ClaimsWithAdditionalCPTs ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ClaimsWithBothMissingAndAdditional",(object?)s.ClaimsWithBothMissingAndAdditional ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@TotalErrorClaims",                  (object?)s.TotalErrorClaims ?? DBNull.Value);
        cmd.Parameters.AddWithValue("@ComplianceRatePct",                 s.ComplianceRatePct);

        cmd.ExecuteNonQuery();
        return true;
    }

    // ?? TVP builder ???????????????????????????????????????????????????????????

    private static DataTable BuildTvp(List<CodingValidationRow> rows)
    {
        var dt = new DataTable();
        dt.Columns.Add("FileLogId");
        dt.Columns.Add("WeekFolder");
        dt.Columns.Add("SourceFilePath");
        dt.Columns.Add("RunNumber");
        dt.Columns.Add("AccessionNo");
        dt.Columns.Add("VisitNumber");
        dt.Columns.Add("PayerName_Raw");
        dt.Columns.Add("Carrier");
        dt.Columns.Add("Payer_Code");
        dt.Columns.Add("PayerCommonCode");
        dt.Columns.Add("Payer_Group_Code");
        dt.Columns.Add("Global_Payer_ID");
        dt.Columns.Add("PayerType");
        dt.Columns.Add("BillingProvider");
        dt.Columns.Add("ReferringProvider");
        dt.Columns.Add("ClinicName");
        dt.Columns.Add("SalesRepname");
        dt.Columns.Add("PatientID");
        dt.Columns.Add("PatientDOB");
        dt.Columns.Add("DateofService");
        dt.Columns.Add("ChargeEnteredDate");
        dt.Columns.Add("FirstBillDate");
        dt.Columns.Add("PanelName");
        dt.Columns.Add("POS");
        dt.Columns.Add("TOS");
        dt.Columns.Add("TotalCharge");
        dt.Columns.Add("AllowedAmount");
        dt.Columns.Add("InsurancePayment");
        dt.Columns.Add("PatientPayment");
        dt.Columns.Add("TotalPayments");
        dt.Columns.Add("InsuranceAdjustments");
        dt.Columns.Add("PatientAdjustments");
        dt.Columns.Add("TotalAdjustments");
        dt.Columns.Add("InsuranceBalance");
        dt.Columns.Add("PatientBalance");
        dt.Columns.Add("TotalBalance");
        dt.Columns.Add("CheckDate");
        dt.Columns.Add("ClaimStatus");
        dt.Columns.Add("DenialCode");
        dt.Columns.Add("ICDCode");
        dt.Columns.Add("DaystoDOS");
        dt.Columns.Add("RollingDays");
        dt.Columns.Add("DaystoBill");
        dt.Columns.Add("DaystoPost");
        dt.Columns.Add("ICDPointer");
        dt.Columns.Add("ActualCPTCode");
        dt.Columns.Add("ExpectedCPTCode");
        dt.Columns.Add("MissingCPTCodes");
        dt.Columns.Add("AdditionalCPTCodes");
        dt.Columns.Add("MissingCPT_Charges");
        dt.Columns.Add("MissingCPT_ChargeSource");
        dt.Columns.Add("AdditionalCPT_Charges");
        dt.Columns.Add("AdditionalCPT_ChargeSource");
        dt.Columns.Add("ExpectedCharges");
        dt.Columns.Add("ValidationStatus");
        dt.Columns.Add("Remarks");
        dt.Columns.Add("MissingCPT_AvgAllowedAmount");
        dt.Columns.Add("MissingCPT_AvgPaidAmount");
        dt.Columns.Add("MissingCPT_AvgPatientResponsibilityAmount");
        dt.Columns.Add("AdditionalCPT_AvgAllowedAmount");
        dt.Columns.Add("AdditionalCPT_AvgPaidAmount");
        dt.Columns.Add("AdditionalCPT_AvgPatientResponsibilityAmount");
        dt.Columns.Add("LabID");
        dt.Columns.Add("LabName");

        foreach (var r in rows)
        {
            dt.Rows.Add(
                r.FileLogId, r.WeekFolder, r.SourceFilePath, r.RunNumber,
                r.AccessionNo, r.VisitNumber, r.PayerName_Raw, r.Carrier,
                r.Payer_Code, r.PayerCommonCode, r.Payer_Group_Code, r.Global_Payer_ID, r.PayerType,
                r.BillingProvider, r.ReferringProvider, r.ClinicName, r.SalesRepname,
                r.PatientID, r.PatientDOB, r.DateofService, r.ChargeEnteredDate, r.FirstBillDate,
                r.PanelName, r.POS, r.TOS,
                r.TotalCharge, r.AllowedAmount, r.InsurancePayment, r.PatientPayment, r.TotalPayments,
                r.InsuranceAdjustments, r.PatientAdjustments, r.TotalAdjustments,
                r.InsuranceBalance, r.PatientBalance, r.TotalBalance,
                r.CheckDate, r.ClaimStatus, r.DenialCode, r.ICDCode,
                r.DaystoDOS, r.RollingDays, r.DaystoBill, r.DaystoPost, r.ICDPointer,
                r.ActualCPTCode, r.ExpectedCPTCode, r.MissingCPTCodes, r.AdditionalCPTCodes,
                r.MissingCPT_Charges, r.MissingCPT_ChargeSource,
                r.AdditionalCPT_Charges, r.AdditionalCPT_ChargeSource, r.ExpectedCharges,
                r.ValidationStatus, r.Remarks,
                r.MissingCPT_AvgAllowedAmount, r.MissingCPT_AvgPaidAmount, r.MissingCPT_AvgPatientResponsibilityAmount,
                r.AdditionalCPT_AvgAllowedAmount, r.AdditionalCPT_AvgPaidAmount, r.AdditionalCPT_AvgPatientResponsibilityAmount,
                r.LabID, r.LabName);
        }

        return dt;
    }
}
