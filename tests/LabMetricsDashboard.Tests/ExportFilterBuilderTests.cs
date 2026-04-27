using System;
using System.Collections.Generic;
using System.Data;
using LabMetricsDashboard.Services;
using Microsoft.Data.SqlClient;
using Xunit;

namespace LabMetricsDashboard.Tests
{
    public class ExportFilterBuilderTests
    {
        [Fact]
        public void BuildExportFilters_NoFilters_ReturnsEmpty()
        {
            var (whereStr, parms) = SqlProductionReportRepository.BuildExportFilters(null, null, null, null, null, null, null, null, "ce");
            Assert.True(string.IsNullOrEmpty(whereStr));
            Assert.Empty(parms);
        }

        [Fact]
        public void BuildExportFilters_PayerAndPanelAndDosFrom_AddsParameters()
        {
            var payers = new List<string> { "Alpha", "Beta" };
            var panels = new List<string> { "P1" };
            var dosFrom = new DateOnly(2025, 1, 1);

            var (whereStr, parms) = SqlProductionReportRepository.BuildExportFilters(payers, panels, dosFrom, null, null, null, null, null, "ce");

            Assert.Contains("LTRIM(RTRIM(PayerName)) IN (", whereStr);
            Assert.Contains("LTRIM(RTRIM(PanelName)) IN (", whereStr);
            Assert.Contains("TRY_CAST(DateOfService AS DATE) >= @cedosFrom", whereStr);

            // parameters should include payer params (2), panel param (1), dosFrom param (1)
            Assert.Equal(4, parms.Count);
            Assert.Contains(parms, p => p.ParameterName == "@cepn0" && (string)p.Value == "Alpha");
            Assert.Contains(parms, p => p.ParameterName == "@cepn1" && (string)p.Value == "Beta");
            Assert.Contains(parms, p => p.ParameterName == "@cepl0" && (string)p.Value == "P1");
            Assert.Contains(parms, p => p.ParameterName == "@cedosFrom" && ((DateTime)p.Value).Date == dosFrom.ToDateTime(new TimeOnly(0)).Date);
        }

        [Fact]
        public void BuildExportFilters_FirstBilledRange_AddsFirstBilledParameters()
        {
            var fbFrom = new DateOnly(2024, 6, 1);
            var fbTo = new DateOnly(2024, 6, 30);

            var (whereStr, parms) = SqlProductionReportRepository.BuildExportFilters(null, null, null, null, null, null, fbFrom, fbTo, "le");

            Assert.Contains("TRY_CAST(FirstBilledDate AS DATE) >= @lefirstBilledFrom", whereStr);
            Assert.Contains("TRY_CAST(FirstBilledDate AS DATE) <= @lefirstBilledTo", whereStr);

            Assert.Equal(2, parms.Count);
            Assert.Contains(parms, p => p.ParameterName == "@lefirstBilledFrom" && ((DateTime)p.Value).Date == fbFrom.ToDateTime(new TimeOnly(0)).Date);
            Assert.Contains(parms, p => p.ParameterName == "@lefirstBilledTo" && ((DateTime)p.Value).Date == fbTo.ToDateTime(new TimeOnly(0)).Date);
        }
    }
}
