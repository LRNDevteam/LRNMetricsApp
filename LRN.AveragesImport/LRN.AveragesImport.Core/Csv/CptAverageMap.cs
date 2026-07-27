using CsvHelper.Configuration;
using LRN.AveragesImport.Core.Models;

namespace LRN.AveragesImport.Core.Csv;

/// <summary>
/// Header names are exact. The CSV "LabID" column contains the lab NAME
/// and is mapped to LabName — never to the numeric lab id.
/// </summary>
public sealed class CptAverageMap : ClassMap<CptAverageRecord>
{
    public CptAverageMap()
    {
        Map(m => m.LabName).Name("LabID");
        Map(m => m.PayerCommonCode).Name("PayerCommonCode");
        Map(m => m.PayerDisplayName).Name("PayerDisplayName");
        Map(m => m.CptCode).Name("CPTCode");
        Map(m => m.AvgUnits).Name("AvgUnits");
        Map(m => m.PanelName).Name("PanelName");
        Map(m => m.WindowType).Name("WindowType");
        Map(m => m.StartDate).Name("StartDate");
        Map(m => m.EndDate).Name("EndDate");
        Map(m => m.AsOfDateTime).Name("AsOfDateTime");
        Map(m => m.PaidLineCount).Name("PaidLineCount");
        Map(m => m.AvgChargeAmountPerUnit).Name("AvgChargeAmountPerUnit");
        Map(m => m.AvgPaidAmountPerUnit).Name("AvgPaidAmountPerUnit");
        Map(m => m.AvgAllowedAmountPerUnit).Name("AvgAllowedAmountPerUnit");
        Map(m => m.AvgPatientPaidAmountPerUnit).Name("AvgPatientPaidAmountPerUnit");
        Map(m => m.AvgPatientResponsibilityPerUnit).Name("AvgPatientResponsibilityPerUnit");
        Map(m => m.MedianPaidAmount).Name("MedianPaidAmount");
        Map(m => m.P25PaidAmount).Name("P25PaidAmount");
        Map(m => m.P75PaidAmount).Name("P75PaidAmount");
        Map(m => m.TotalLineCount).Name("TotalLineCount");
        Map(m => m.DeniedLineCount).Name("DeniedLineCount");
        Map(m => m.AdjustedLineCount).Name("AdjustedLineCount");
        Map(m => m.LastSeenDos).Name("LastSeenDOS");
        Map(m => m.GlobalPayerId).Name("Global_Payer_ID");
    }
}
