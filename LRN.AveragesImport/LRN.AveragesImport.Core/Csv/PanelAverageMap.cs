using CsvHelper.Configuration;
using LRN.AveragesImport.Core.Models;

namespace LRN.AveragesImport.Core.Csv;

/// <summary>
/// Header names are exact. The CSV "LabID" column contains the lab NAME
/// and is mapped to LabName — never to the numeric lab id.
/// </summary>
public sealed class PanelAverageMap : ClassMap<PanelAverageRecord>
{
    public PanelAverageMap()
    {
        Map(m => m.LabName).Name("LabID");
        Map(m => m.PayerId).Name("PayerID");
        Map(m => m.PayerDisplayName).Name("PayerDisplayName");
        Map(m => m.PanelName).Name("PanelName");
        Map(m => m.WindowType).Name("WindowType");
        Map(m => m.StartDate).Name("StartDate");
        Map(m => m.EndDate).Name("EndDate");
        Map(m => m.AsOfDateTime).Name("AsOfDateTime");
        Map(m => m.PaidLineCount).Name("PaidLineCount");
        Map(m => m.AvgChargeAmount).Name("AvgChargeAmount");
        Map(m => m.AvgPaidAmount).Name("AvgPaidAmount");
        Map(m => m.AvgAllowedAmount).Name("AvgAllowedAmount");
        Map(m => m.AvgPatientPaidAmount).Name("AvgPatientPaidAmount");
        Map(m => m.AvgPatientResponsibility).Name("AvgPatientResponsibility");
        Map(m => m.MedianPaidAmount).Name("MedianPaidAmount");
        Map(m => m.P25PaidAmount).Name("P25PaidAmount");
        Map(m => m.P75PaidAmount).Name("P75PaidAmount");
        Map(m => m.TotalLineCount).Name("TotalLineCount");
        Map(m => m.DeniedLineCount).Name("DeniedLineCount");
        Map(m => m.AdjustedLineCount).Name("AdjustedLineCount");
        Map(m => m.LastSeenDos).Name("LastSeenDOS");
    }
}
