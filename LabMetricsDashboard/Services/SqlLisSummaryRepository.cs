using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public sealed class SqlLisSummaryRepository : ILisSummaryRepository
{
	private sealed record RawLisGroup(
		Dictionary<string, string> Fields,
		int CollectedYear,
		int CollectedMonth,
		int TotalClaims);

	private sealed record DimensionProfile(
		string LogicSheetName,
		string DateColumn,
		string? CountDistinctColumn,
		string? IncorrectDosColumn,
		Dictionary<string, string?> FieldColumns);

	private sealed record TemplateRow(string Code, string Description, string Logic);

	private static readonly IReadOnlyDictionary<string, TemplateRow[]> SheetTemplates = new Dictionary<string, TemplateRow[]>(StringComparer.OrdinalIgnoreCase)
	{
		["NWL"] = new[] {
				new TemplateRow("A", "Insurance Bill", "Bill To = Insurance Bill"),
				new TemplateRow("1", "Billed", "Bill To = Insurance Bill AND Bill Status = Billed"),
				new TemplateRow("•", "Claim Submitted in Webpm", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Claim Submitted in Webpm"),
				new TemplateRow("•", "Claim Submitted in Daqbilling", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Claim Submitted in DaqBilling"),
				new TemplateRow("•", "Claim Submitted in Daq & Webpm", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Claim Submitted in Daq & Webpm"),
				new TemplateRow("•", "Non Billable - Excluded Organizations", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Non Billable - Excluded Organizations"),
				new TemplateRow("•", "Manually Pushed in Emedix", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Manually Pushed in Emedix"),
				new TemplateRow("2", "Unbilled", "Bill To = Insurance Bill AND Bill Status = Unbilled"),
				new TemplateRow("•", "Charge Not Created", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created"),
				new TemplateRow("•", "Webpm", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Source = Webpm"),
				new TemplateRow("*", "No Charges found in Webpm", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Source = Webpm AND Charges not entered status = No Charges found in Webpm"),
				new TemplateRow("*", "Unposted Charges in Webpm", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Source = Webpm AND Charges not entered status = Unposted Charges in Webpm"),
				new TemplateRow("•", "Daqbilling", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Source = Daqbilling"),
				new TemplateRow("•", "Non Billable - Excluded Validity Codes", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded Validity Codes"),
				new TemplateRow("•", "Non Billable - Excluded PAP Codes", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded PAP Codes"),
				new TemplateRow("•", "Non Billable - Excluded Organizations", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded Organizations"),
				new TemplateRow("•", "Charges Created and Not Submitted", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted"),
				new TemplateRow("•", "Webpm", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted AND Source = Webpm"),
				new TemplateRow("•", "Daqbilling", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted AND Source = Daqbilling"),
				new TemplateRow("B", "Yet to be validate", "Bill To = Yet to be validate"),
				new TemplateRow("1", "Billed", "Bill To = Yet to be validate AND Bill Status = Billed"),
				new TemplateRow("2", "Unbilled", "Bill To = Yet to be validate AND Bill Status = Unbilled"),
				new TemplateRow("•", "Not Resulted", "Bill To = Yet to be validate AND Bill Status = Unbilled AND Final Status 2 = Not Resulted"),
				new TemplateRow("•", "Non Billable", "Bill To = Yet to be validate AND Bill Status = Unbilled AND Final Status 2 = Non Billable"),
				new TemplateRow("•", "Charges Created and Not Submitted", "Bill To = Yet to be validate AND Bill Status = Unbilled AND Final Status 2 = Charges Created and Not Submitted"),
				new TemplateRow("C", "Self pay", "Bill To = Self pay"),
				new TemplateRow("1", "Billed", "Bill To = Self pay AND Bill Status = Billed"),
				new TemplateRow("2", "Unbilled", "Bill To = Self pay AND Bill Status = Unbilled"),
				new TemplateRow("•", "Non Billable", "Bill To = Self pay AND Bill Status = Unbilled AND Final Status 2 = Non Billable"),
				new TemplateRow("•", "Self Pay", "Bill To = Self pay AND Bill Status = Unbilled AND Final Status 2 = Self Pay"),
				new TemplateRow("•", "Charges Created and Not Submitted", "Bill To = Self pay AND Bill Status = Unbilled AND Final Status 2 = Charges Created and Not Submitted"),
				new TemplateRow("D", "ADCS Claims", "Bill To = ADCS Claims"),
				new TemplateRow("1", "Billed", "Bill To = ADCS Claims AND Bill Status = Billed"),
				new TemplateRow("2", "Unbilled", "Bill To = ADCS Claims AND Bill Status = Unbilled"),
				new TemplateRow("•", "Non Billable", "Bill To = ADCS Claims AND Bill Status = Unbilled AND Final Status 2 = Non Billable"),
				new TemplateRow("E", "Client Bills", "Bill To = Client Bills"),
				new TemplateRow("1", "Billed", "Bill To = Client Bills AND Bill Status = Billed"),
				new TemplateRow("2", "Unbilled", "Bill To = Client Bills AND Bill Status = Unbilled"),
				new TemplateRow("•", "Non Billable", "Bill To = Client Bills AND Bill Status = Unbilled AND Final Status 2 = Non Billable"),
				new TemplateRow("•", "Do Not Bill", "Bill To = Client Bills AND Bill Status = Unbilled AND Final Status 2 = Do Not Bill"),
				new TemplateRow("•", "Charges Created and Not Submitted", "Bill To = Client Bills AND Bill Status = Unbilled AND Final Status 2 = Charges Created and Not Submitted"),
				new TemplateRow("F", "System Test", "Bill To = System Test"),
				new TemplateRow("1", "Billed", "Bill To = System Test AND Bill Status = Billed"),
				new TemplateRow("2", "Unbilled", "Bill To = System Test AND Bill Status = Unbilled"),
				new TemplateRow("•", "Non Billable", "Bill To = System Test AND Bill Status = Unbilled AND Final Status 2 = Non Billable"),
				new TemplateRow("•", "Test Samples", "Bill To = System Test AND Bill Status = Unbilled AND Final Status 2 = Test Samples"),
				new TemplateRow("G", "Rejections", "Bill To = Rejections"),
				new TemplateRow("1", "Billed", "Bill To = Rejections AND Bill Status = Billed"),
				new TemplateRow("2", "Unbilled", "Bill To = Rejections AND Bill Status = Unbilled"),
				new TemplateRow("•", "Sample Rejected", "Bill To = Rejections AND Bill Status = Unbilled AND Final Status 2 = Sample Rejected"),
				new TemplateRow("", "Total Samples", "Total Samples"),
			},
		["Augustus"] = new[] {
				new TemplateRow("A", "Insurance Bills", "Bill to = Insurance Bills"),
				new TemplateRow("1", "Billed", "Bill to = Insurance Bills AND Bill status = Billed"),
				new TemplateRow("•", "Claim Submitted in IRCM", "Bill to = Insurance Bills AND Bill status = Billed AND Final Status =  Claim Submitted in IRCM"),
				new TemplateRow("•", "Claim Submitted in Daqbilling", "Bill to = Insurance Bills AND Bill status = Billed AND Final Status =  Claim Submitted in Daqbilling"),
				new TemplateRow("2", "Unbilled", "Bill to = Insurance Bills AND Bill status = Unbilled"),
				new TemplateRow("•", "Resulted yet to be billed", "Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status =  Resulted yet to be billed"),
				new TemplateRow("*", "Ready to bill", "Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status =  Resulted yet to be billed"),
				new TemplateRow("•", "Insurance name not listed", "Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status =  Insurance Name Not Listed"),
				new TemplateRow("B", "Yet to be Validated", "Bill to = Yet to be Validated"),
				new TemplateRow("1", "Billed", "Bill to = Yet to be Validated AND Bill Status = Billed"),
				new TemplateRow("C", "Client Bills", "Bill to = Client Bills"),
				new TemplateRow("1", "Billed", "Bill to = Client Bills AND Bill Status = Billed"),
				new TemplateRow("D", "System Test", "Bill to = System Test"),
				new TemplateRow("1", "Billed", "Bill to = System Test AND Bill Status = Billed"),
				new TemplateRow("E", "Self pay", "Bill to = Self pay"),
				new TemplateRow("1", "Billed", "Bill to = Self pay AND Bill Status = Billed"),
			},
		["Certus"] = new[] {
				new TemplateRow("A", "Insurance Bill", "Bill to = Insurance Bill"),
				new TemplateRow("1", "Billed", "Bill to = Insurance Bill AND Billing status = Billed"),
				new TemplateRow("•", "Claim submitted in Daqbilling", "Bill to = Insurance Bill AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling"),
				new TemplateRow("2", "Not Billed", "Bill to = Insurance Bill AND Billing status = Not Billed"),
				new TemplateRow("•", "Claim Entered in Daqbilling", "Bill to = Insurance Bill AND Billing status = Not Billed AND Final Status = Claim Entered in Daqbilling"),
				new TemplateRow("•", "Resulted yet to be billed", "Bill to = Insurance Bill AND Billing status = Not Billed AND Final Status = Resulted yet to be billed"),
				new TemplateRow("•", "D/L Isomer", "Bill to = Insurance Bill AND Billing status = Not Billed AND Final Status = D/L Isomer"),
				new TemplateRow("B", "Duplicate", "Bill to = Duplicate"),
				new TemplateRow("1", "Billed", "Bill to = Duplicate AND Billing status = Billed"),
				new TemplateRow("•", "Claim submitted in Daqbilling", "Bill to = Duplicate AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling"),
				new TemplateRow("C", "Client Bill", "Bill to = Client Bill"),
				new TemplateRow("1", "Billed", "Bill to = Client Bill AND Billing status = Billed"),
				new TemplateRow("•", "Claim submitted in Daqbilling", "Bill to = Client Bill AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling"),
				new TemplateRow("D", "Yet to be Validated", "Bill to = Yet to be Validated"),
				new TemplateRow("1", "Billed", "Bill to = Yet to be Validated AND Billing status = Billed"),
				new TemplateRow("•", "Claim submitted in Daqbilling", "Bill to = Yet to be Validated AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling"),
				new TemplateRow("E", "Selfpay", "Bill to = Selfpay"),
				new TemplateRow("1", "Billed", "Bill to = Selfpay AND Billing status = Billed"),
				new TemplateRow("•", "Claim submitted in Daqbilling", "Bill to = Selfpay AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling"),
				new TemplateRow("F", "Rejection", "Bill to = Rejection"),
				new TemplateRow("1", "Billed", "Bill to = Rejection AND Billing status = Billed"),
				new TemplateRow("•", "Claim submitted in Daqbilling", "Bill to = Rejection AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling"),
				new TemplateRow("G", "System Test", "Bill to = System Test"),
				new TemplateRow("1", "Billed", "Bill to = System Test AND Billing status = Billed"),
				new TemplateRow("•", "Claim submitted in Daqbilling", "Bill to = System Test AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling"),
			},
		["Cove"] = new[] {
				new TemplateRow("A", "Billable", "Final Status = [Billable]"),
				new TemplateRow("•", "UTI", "Final Status = [Billable] AND Panel Type = [UTI]"),
				new TemplateRow("•", "Wound", "Final Status = [Billable] AND Panel Type = [Wound]"),
				new TemplateRow("•", "RPP", "Final Status = [Billable] AND Panel Type = [RPP]"),
				new TemplateRow("•", "Womens Health", "Final Status = [Billable] AND Panel Type = [Womens Health]"),
				new TemplateRow("•", "GI", "Final Status = [Billable] AND Panel Type = [GI]"),
				new TemplateRow("•", "Urinalysis", "Final Status = [Billable] AND Panel Type = [Urinalysis]"),
				new TemplateRow("•", "Fungus", "Final Status = [Billable] AND Panel Type = [Fungus]"),
				new TemplateRow("•", "STI", "Final Status = [Billable] AND Panel Type = [STI]"),
				new TemplateRow("•", "Tox", "Final Status = [Billable] AND Panel Type = [Tox]"),
				new TemplateRow("•", "Fungus + Wound", "Final Status = [Billable] AND Panel Type = [Fungus + Wound]"),
				new TemplateRow("•", "PGx", "Final Status = [Billable] AND Panel Type = [PGX]"),
				new TemplateRow("•", "Neurocognitive", "Final Status = [Billable] AND Panel Type = [Neurocognitive]"),
				new TemplateRow("•", "Immunodeficiency", "Final Status = [Billable] AND Panel Type = [Immunodeficiency]"),
				new TemplateRow("•", "CGx", "Final Status = [Billable] AND Panel Type = [CGx]"),
				new TemplateRow("•", "Unable To Locate", "Final Status = [Billable] AND Panel Type = [Unable To Locate]"),
				new TemplateRow("•", "Thyroid", "Final Status = [Billable] AND Panel Type = [Thyroid]"),
				new TemplateRow("1", "Billed", "Final Status = [Billable] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "Not Billed", "Final Status = [Billable] AND Billed/Not = [Not Billed]"),
				new TemplateRow("•", "Ready To Bill", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Ready To Bill]"),
				new TemplateRow("•", "Ignored - CP Exception", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Ignored - CP Exception]"),
				new TemplateRow("•", "Ignored - Client Response Pure Selfpay", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Ignored - Client Response Pure Selfpay]"),
				new TemplateRow("•", "Billed In Elixir Dx", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Billed In Elixir Dx]"),
				new TemplateRow("•", "Client Bill Cases", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Client Bill Cases]"),
				new TemplateRow("•", "Ignored - NGS & PGX in Cove", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Ignored - NGS & PGX in Cove]"),
				new TemplateRow("•", "Ignored - Duplicate Accession", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Ignored - Duplicate Accession]"),
				new TemplateRow("•", "Coding exception -In review", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Coding exception -In review]"),
				new TemplateRow("•", "In process", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [In process]"),
				new TemplateRow("•", "CP Exception", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [CP Exception]"),
				new TemplateRow("•", "Coding exception", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Coding exception]"),
				new TemplateRow("•", "Discovery File need to be sent to Medlytix", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Discovery File need to be sent to Medlytix]"),
				new TemplateRow("•", "Ignored - Medicaid AR Prior to Sep 19'2025", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Ignored - Medicaid AR Prior to Sep 19'2025]"),
				new TemplateRow("•", "Discovery File sent to Medlytix", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Discovery File sent to Medlytix]"),
				new TemplateRow("•", "Ignored - Reported in Elixir Truemed", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Ignored - Reported in Elixir Truemed]"),
				new TemplateRow("•", "Hold-Amerihealth Lousiana", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Hold-Amerihealth Lousiana]"),
				new TemplateRow("•", "Medicaid Credentialling In Process", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Medicaid Credentialling In Process]"),
				new TemplateRow("•", "Selfpay", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Selfpay]"),
				new TemplateRow("•", "Referring provider Issues", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Referring provider Issues]"),
				new TemplateRow("•", "Billed In Variantx Lab", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Billed In Variantx Lab]"),
				new TemplateRow("•", "Billed Insurance In Covedx", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Billed Insurance In Covedx]"),
				new TemplateRow("•", "Ignored - Client Response Non Billiable", "Final Status = [Billable] AND Billed/Not = [Not Billed] AND Sub Status = [Ignored - Client Response Non Billiable]"),
				new TemplateRow("B", "System Test", "Final Status = [System Test]"),
				new TemplateRow("1", "Billed", "Final Status = [System Test] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "UnBilled", "Final Status = [System Test] AND Billed/Not = [Unbilled]"),
				new TemplateRow("C", "Self Pay", "Final Status = [Self Pay]"),
				new TemplateRow("1", "Billed", "Final Status = [Self Pay] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "UnBilled", "Final Status = [Self Pay] AND Billed/Not = [Unbilled]"),
				new TemplateRow("D", "Deleted/Rejected", "Final Status = [Deleted/Rejected]"),
				new TemplateRow("1", "Billed", "Final Status = [Deleted/Rejected] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "UnBilled", "Final Status = [Deleted/Rejected] AND Billed/Not = [Unbilled]"),
				new TemplateRow("E", "Client Bill", "Final Status = [Client Bill]"),
				new TemplateRow("1", "Billed", "Final Status = [Client Bill] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "UnBilled", "Final Status = [Client Bill] AND Billed/Not = [Unbilled]"),
				new TemplateRow("F", "Yet To Be Validated", "Final Status = [Yet To Be Validated]"),
				new TemplateRow("G", "Ref Lab - Bill Patient", "Final Status = [Ref Lab - Bill Patient]"),
				new TemplateRow("H", "Missing Accession", "Final Status = [Missing Accession]"),
			},
		["Elixir"] = new[] {
				new TemplateRow("", "Total Samples", "Count [Order ID]"),
				new TemplateRow("A", "Insurance Bill", "Final Status = [Billable]"),
				new TemplateRow("1", "Billed", "Final Status = [Billable] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "Not Billed", "Final Status = [Billable] AND Billed/Not = [Not Billed]"),
				new TemplateRow("•", "Resulted yet to be billed", "Final Status = [Billable] AND Billed/Not = [Not Billed]"),
				new TemplateRow("B", "Client Bill", "Final Status = [Client Bill]"),
				new TemplateRow("C", "Self Pay", "Final Status = [Self Pay]"),
				new TemplateRow("1", "Billed", "Final Status = [Self Pay] AND Billed/Not = [Billed]"),
				new TemplateRow("D", "System Test", "Final Status = [System Test]"),
				new TemplateRow("1", "Billed", "Final Status = [System Test] AND Billed/Not = [Billed]"),
				new TemplateRow("E", "Deleted/Rejected", "Final Status = [Deleted/Rejected]"),
				new TemplateRow("F", "Yet to be validated", "Final Status = [Yet to be validated]"),
				new TemplateRow("G", "CIP/Pending", "Final Status = [CIP/Pending]"),
				new TemplateRow("1", "Billed", "Final Status = [CIP/Pending] AND Billed/Not = [Billed]"),
				new TemplateRow("•", "Pending Smart PGx", "Final Status = [CIP/Pending] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "Not Billed", "Final Status = [CIP/Pending] AND Billed/Not = [Not Billed]"),
				new TemplateRow("•", "SaveForSignature", "Final Status = [CIP/Pending] AND Billed/Not = [Not Billed] AND Payment Method != [Blank]"),
				new TemplateRow("•", "Missing info", "Final Status = [CIP/Pending] AND Billed/Not = [Not Billed] AND Payment Method = [Blank]"),
			},
		["Beech Tree"] = new[] {
				new TemplateRow("", "Total Samples", "Count [Order ID]"),
				new TemplateRow("A", "Billable Samples - Resulted", "Resulted / Not = [Resulted]"),
				new TemplateRow("1", "Billed to Insurance", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Blank]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Blank]"),
				new TemplateRow("2", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank AND Billing Review Required]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Sample Status = [Received] AND Client Status = [Blank AND Billing Review Required]"),
				new TemplateRow("•", "Billing Review Required", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled]  AND Sample Status = [Received] AND Client Status = [Billing Review Required]"),
				new TemplateRow("•", "In Transit", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Sample Status = [In Transit] AND Client Status = [Blank AND Billing Review Required]"),
				new TemplateRow("•", "Transferred", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Sample Status = [Transferred] AND Client Status = [Blank AND Billing Review Required]"),
				new TemplateRow("•", "Collected", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Sample Status = [Collected] AND Client Status = [Blank AND Billing Review Required]"),
				new TemplateRow("3", "Unbilled", "Resulted / Not = [Resulted] AND Claim Status = [Entered] AND Billed/Not = UnBilled AND Client Status = [Blank]"),
				new TemplateRow("4", "Client Bill", "Resulted / Not = [Resulted] AND Claim Status = [ALL] AND Billed/Not = [Billed AND Unbilled] AND Client Status = [Client Bill]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [Unbilled] AND Client Status = [Client Bill]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Client Bill]"),
				new TemplateRow("5", "Self Pay", "Resulted / Not = [Resulted] AND Claim Status = [All] AND Billed/Not = [ALL] AND Client Status = [Self Pay]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Self Pay]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Self Pay]"),
				new TemplateRow("•", "Entered", "Resulted / Not = [Resulted] AND Claim Status = [Entered] AND Billed/Not = [UnBilled] AND Client Status = [Self Pay]"),
				new TemplateRow("6", "Test Entries", "Resulted / Not = [Resulted] AND Claim Status = [All] AND Billed/Not = [ALL] AND Client Status = [Test Entries] AND Payment Method != [No Bill]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Test Entries] AND Payment Method != [No Bill]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Test Entries] AND Payment Method != [No Bill]"),
				new TemplateRow("7", "Rejected Sample", "Resulted / Not = [Resulted] AND Claim Status = [All] AND Billed/Not = [ALL] AND Client Status = [Rejected Sample]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Rejected Sample]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Rejected Sample]"),
				new TemplateRow("8", "Payment Method No Bill", "Resulted / Not = [Resulted] AND Payment Method = [No Bill]"),
				new TemplateRow("B", "Not Resulted", "Resulted / Not = [Not Resulted]"),
				new TemplateRow("1", "No Result date on LIS but Billed", "Resulted / Not = [Not Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Blank]"),
				new TemplateRow("2", "Not Entered in AMD", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank] AND Sample Status = [Received]"),
				new TemplateRow("•", "In Transit", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank] AND Sample Status = [In Transit]"),
				new TemplateRow("•", "Collected", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank] AND Sample Status = [Collected]"),
				new TemplateRow("•", "Transferred", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank] AND Sample Status = [Transferred]"),
				new TemplateRow("3", "Client Bill", "Resulted / Not = [Not Resulted] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [Client Bill]"),
				new TemplateRow("4", "Self Pay", "Resulted / Not = [Not Resulted] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [Self Pay]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Self Pay]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Not Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Self Pay]"),
				new TemplateRow("5", "Test Entries", "Resulted / Not = [Not Resulted] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [Test Entries]"),
				new TemplateRow("6", "Rejected Sample", "Resulted / Not = [Not Resulted] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [Rejected Sample]"),
		},
		["InHealth"] = new[] {
				new TemplateRow("A", "Billable", "NA = Blank AND LRN Sample Status = Billable"),
				new TemplateRow("1", "Billed", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Billed"),
				new TemplateRow("•", "Billed Via AMD", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Billed AND LRN Sub Status = Billed Via AMD"),
				new TemplateRow("2", "Not Billed", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Not Billed"),
				new TemplateRow("•", "Nexum_Claim_scrubber_Queue_Eligibility", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Not Billed AND LRN Sub Status = Nexum_Claim_scrubber_Queue_Eligibility"),
				new TemplateRow("•", "Entered in AMD but not billed", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Not Billed AND LRN Sub Status = Entered in AMD but not billed"),
				new TemplateRow("•", "Requires Review", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Not Billed AND LRN Sub Status = Requires Review"),
				new TemplateRow("•", "Nexum Pre Processing Queue", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Not Billed AND LRN Sub Status = Nexum Pre Processing Queue"),
				new TemplateRow("•", "Nexum_Claim_scrubber_Queue_AMD Output", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Not Billed AND LRN Sub Status = Nexum_Claim_scrubber_Queue_AMD Output"),
				new TemplateRow("•", "Nexum_Claim_scrubber_Queue_Diagnosis Validity", "NA = Blank AND LRN Sample Status = Billable AND LRN Bill Category = Not Billed AND LRN Sub Status = Nexum_Claim_scrubber_Queue_Diagnosis Validity"),
				new TemplateRow("B", "Self Pay", "NA = Blank AND LRN Sample Status = Self Pay"),
				new TemplateRow("1", "Billed", "NA = Blank AND LRN Sample Status = Self Pay AND LRN Bill Category = Billed"),
				new TemplateRow("2", "Not Billed", "NA = Blank AND LRN Sample Status = Self Pay AND LRN Bill Category = Not Billed"),
				new TemplateRow("C", "Other Samples", "NA = Blank AND LRN Sample Status = Other Samples"),
				new TemplateRow("1", "Billed", "NA = Blank AND LRN Sample Status = Other Samples AND LRN Bill Category = Billed"),
				new TemplateRow("2", "Not Billed", "NA = Blank AND LRN Sample Status = Other Samples AND LRN Bill Category = Not Billed"),
				new TemplateRow("•", "Ordered", "NA = Blank AND LRN Sample Status = Other Samples AND LRN Bill Category = Not Billed AND Entry_Status = Ordered"),
				new TemplateRow("•", "Unpayable Policies", "NA = Blank AND LRN Sample Status = Other Samples AND LRN Bill Category = Not Billed AND Entry_Status = Unpayable Policies"),
				new TemplateRow("•", "Failed Discovery", "NA = Blank AND LRN Sample Status = Other Samples AND LRN Bill Category = Not Billed AND Entry_Status = Failed Discovery"),
				new TemplateRow("•", "Waiting for Information", "NA = Blank AND LRN Sample Status = Other Samples AND LRN Bill Category = Not Billed AND Entry_Status = Waiting for Information"),
				new TemplateRow("•", "Results Posted", "NA = Blank AND LRN Sample Status = Other Samples AND LRN Bill Category = Not Billed AND Entry_Status = Results Posted"),
				new TemplateRow("D", "System Test", "NA = Blank AND LRN Sample Status = System Test"),
				new TemplateRow("E", "Deleted/Rejected", "NA = Blank AND LRN Sample Status = Deleted/Rejected"),
				new TemplateRow("", "Total Samples", "NA = Blank"),
		},
		["PCRLOA"] = new[] {
				new TemplateRow("", "Total Samples", "Count [Unique Sample ID]"),
				new TemplateRow("A", "Resulted", "Resulted / Not = [Resulted]"),
				new TemplateRow("1", "Billed to Insurance", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Client Status = [Blank]"),
				new TemplateRow("◦", "Claims Billed to Payor via AMD", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Client Status = [Blank]"),
				new TemplateRow("2", "Client Bill", "Resulted / Not = [Resulted] AND Client Status = [Client Bill]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Client Status = [Client Bill] AND Claim Status = [Billed]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Client Status = [Client Bill] AND Claim Status = [Not Entered in AMD]"),
				new TemplateRow("•", "Entered", "Resulted / Not = [Resulted] AND Client Status = [Client Bill] AND Claim Status = [Entered]"),
				new TemplateRow("3", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required, Blank]"),
				new TemplateRow("•", "Completed", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required]"),
				new TemplateRow("•", "Billing Review Required", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required, Blank] AND Order Status = [Completed]"),
				new TemplateRow("•", "In Transit", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required, Blank] AND Order Status = [In Transit]"),
				new TemplateRow("4", "Unbilled", "Resulted / Not = [Resulted] AND Claim Status = [Entered] AND Client Status = [Blank]"),
				new TemplateRow("◦", "Charges Entered in AMD - Not Released to Payor (EDI Hold)", "Resulted / Not = [Resulted] AND Claim Status = [Entered] AND Client Status = [Blank]"),
				new TemplateRow("5", "Test Entries", "Resulted / Not = [Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client Status = [Test Entries]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client Status = [Test Entries]"),
				new TemplateRow("6", "Rejected Sample", "Resulted / Not = [Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client Status = [Rejected Sample]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client Status = [Rejected Sample]"),
				new TemplateRow("B", "Not Resulted", "Resulted / Not = [Not Resulted]"),
				new TemplateRow("1", "Not Entered in AMD", "Resulted / Not = [Not Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank]"),
				new TemplateRow("•", "In Transit", "Resulted / Not = [Not Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank] AND Order Status = [In Transit]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Not Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank] AND Order Status = [Received]"),
				new TemplateRow("2", "Client Bill", "Resulted / Not = [Not Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client  Status = [Client Bill]"),
				new TemplateRow("3", "Test Entries", "Resulted / Not = [Not Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client  Status = [Test Entries]"),
				new TemplateRow("4", "Rejected Sample", "Resulted / Not = [Not Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client  Status = [Rejected Sample]"),
				new TemplateRow("5", "Self Pay", "Resulted / Not = [Not Resulted] AND Billed/Not = [UnBilled] AND Claim Status = [Not Entered in AMD] AND Client  Status = [Self Pay]"),
		},
		["PhiLifeLegacy"] = new[] {
				new TemplateRow("", "Total Samples", "Count [Unique Sample ID]"),
				new TemplateRow("A", "Billable Samples - Resulted", "Resulted / Not = [Resulted]"),
				new TemplateRow("1", "Billed to Insurance", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Blank AND Billing Review Required]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Blank AND Billing Review Required]"),
				new TemplateRow("2", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank AND Billing Review Required] AND Payment Method = [Insurance]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank AND Billing Review Required] AND Payment Method = [Insurance] AND Sample Status = [Received]"),
				new TemplateRow("•", "Billing Review Required", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank AND Billing Review Required] AND Payment Method = [Insurance] AND Sample Status = [Received] AND Client Status = [Billing Review Required]"),
				new TemplateRow("•", "Collected", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Blank AND Billing Review Required] AND Payment Method = [Insurance] AND Sample Status = [Collected]"),
				new TemplateRow("3", "Rejected Samples", "Resulted / Not = [Resulted] AND Claim Status = [All] AND Billed/Not = [All] AND Client Status = [Rejected Sample]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Rejected Sample]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [Unbilled] AND Client Status = [Rejected Sample]"),
				new TemplateRow("4", "Client Bill", "Resulted / Not = [Resulted] AND Claim Status = [All] AND Billed/Not = [All] AND Client Status = [Client Bill]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Client Bill]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Client Bill]"),
				new TemplateRow("5", "Test Entries", "Resulted / Not = [Resulted] AND Claim Status = [All] AND Billed/Not = [All] AND Client Status = [Test Entries]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Test Entries]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Test Entries]"),
				new TemplateRow("6", "Unbilled", "Resulted / Not = [Resulted] AND Claim Status = [Entered] AND Billed/Not = UnBilled"),
				new TemplateRow("7", "Self Pay", "Resulted / Not = [Resulted] AND Claim Status = [All] AND Billed/Not = [All] AND Client Status = [Self Pay]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Self Pay]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Self Pay]"),
				new TemplateRow("8", "Payment Method No Bill", "Resulted / Not = [Resulted] AND Payment Method = No Bill"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Payment Method = No Bill AND Claim Status = Billed in AMD"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Payment Method = No Bill AND Claim Status = Not Entered in AMD"),
				new TemplateRow("B", "Not Resulted", "Resulted / Not = Not Resulted"),
				new TemplateRow("1", "Not Entered in AMD", "Resulted / Not = [Not Resulted] AND Payment Method = Insurance AND Claim Status = Not Entered in AMD AND Billed/Not = [UnBilled] AND Client Status = [Blank]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Not Resulted] AND Payment Method = Insurance AND Claim Status = Not Entered in AMD AND Billed/Not = [UnBilled] AND Client Status = [Blank] AND Sample Status = [Received]"),
				new TemplateRow("•", "Collected", "Resulted / Not = [Not Resulted] AND Payment Method = Insurance AND Claim Status = Not Entered in AMD AND Billed/Not = [UnBilled] AND Client Status = [Blank] AND Sample Status = [Collected]"),
				new TemplateRow("•", "Transferred", "Resulted / Not = [Not Resulted] AND Payment Method = Insurance AND Claim Status = Not Entered in AMD AND Billed/Not = [UnBilled] AND Client Status = [Blank] AND Sample Status = [Transferred]"),
				new TemplateRow("3", "Rejected Samples", "Resulted / Not = [Not Resulted] AND Claim Status = Not Entered in AMD AND Billed/Not = [UnBilled] AND Client Status = [Rejected]"),
				new TemplateRow("2", "Client Bill", "Resulted / Not = [Not Resulted] AND Claim Status = Not Entered in AMD AND Billed/Not = [UnBilled] AND Client Status = [Client Bill]"),
				new TemplateRow("3", "No Result date on LIS but Billed", "Resulted / Not = [Not Resulted] AND Claim Status = Billed AND Billed/Not = [Billed]"),
				new TemplateRow("4", "Test Entries", "Resulted / Not = [Not Resulted] AND Payment Method = Insurance AND Claim Status = Not Entered in AMD AND Billed/Not = [UnBilled] AND Client Status = [Test Entries]"),
				new TemplateRow("5", "Payment Method No Bill", "Resulted / Not = [Not Resulted] AND Payment Method = [No Bill]"),
		},
		["PhiLife"] = new[] {
				new TemplateRow("", "Total Samples", "Count [Unique Sample ID]"),
				new TemplateRow("A", "Billable Samples - Resulted", "Resulted / Not = [Resulted]"),
				new TemplateRow("1", "Billed to Insurance", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Client Status = [Blank]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Claim Status = [Billed] AND Client Status = [Blank]"),
				new TemplateRow("2", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required, Blank] AND Payment Method = [Insurance]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required] AND Payment Method = [Insurance] AND Sample Status = [Received]"),
				new TemplateRow("•", "Billing Review Required", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required] AND Payment Method = [Insurance]"),
				new TemplateRow("•", "Collected", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank] AND Payment Method = [Insurance] AND Sample Status = [Collected]"),
				new TemplateRow("3", "Unbilled", "Resulted / Not = [Resulted] AND Client Status = [Blank] AND Claim Status = [Entered]"),
				new TemplateRow("4", "Client Bill", "Resulted / Not = [Resulted] AND Client Status = [Client Bill]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Client Status = [Client Bill] AND Claim Status = [Not Entered in AMD]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Client Status = [Client Bill] AND Claim Status = [Billed]"),
				new TemplateRow("5", "Self Pay", "Resulted / Not = [Resulted] AND Client Status = [Self Pay]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Client Status = [Self Pay] AND Claim Status = [Billed]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Client Status = [Self Pay] AND Claim Status = [Not Entered in AMD]"),
				new TemplateRow("6", "Test Entries", "Resulted / Not = [Resulted] AND Client Status = [Test Entries] AND Payment Method != [No Bill]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Client Status = [Test Entries] AND Payment Method != [No Bill] AND Claim Status = [Not Entered in AMD]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Client Status = [Test Entries] AND Payment Method != [No Bill] AND Claim Status = [Billed]"),
				new TemplateRow("7", "Rejected Sample", "Resulted / Not = [Resulted] AND Client Status = [Rejected Sample]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Client Status = [Rejected Sample] AND Claim Status = [Not Entered in AMD]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Client Status = [Rejected Sample] AND Claim Status = [Billed]"),
				new TemplateRow("8", "Payment Method No Bill", "Resulted / Not = [Resulted] AND Payment Method = [No Bill]"),
				new TemplateRow("B", "Not Resulted", "Resulted / Not = [Not Resulted]"),
				new TemplateRow("1", "Not Entered in AMD", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank] AND Payment Method = [Insurance]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank] AND Payment Method = [Insurance] AND Sample Status = [Received]"),
				new TemplateRow("•", "Collected", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank] AND Payment Method = [Insurance] AND Sample Status = [Collected]"),
				new TemplateRow("2", "Client Bill", "Resulted / Not = [Not Resulted] AND Client Status = [Client Bill]"),
				new TemplateRow("3", "Test Entries", "Resulted / Not = [Not Resulted] AND Client Status = [Test Entries] AND Payment Method = [Insurance]"),
				new TemplateRow("4", "Rejected Sample", "Resulted / Not = [Not Resulted] AND Client Status = [Rejected Sample] AND Payment Method = [Insurance]"),
				new TemplateRow("5", "Payment Method No Bill", "Resulted / Not = [Not Resulted] AND Payment Method = [No Bill]"),
		},
		["Rising TidesLegacy"] = new[] {
				new TemplateRow("", "Total Samples", "Count [Unique Sample ID]"),
				new TemplateRow("A", "Billable Samples - Resulted", "Resulted / Not = [Resulted]"),
				new TemplateRow("1", "Billed to Insurance", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Billed]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Billed] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Billing Review Required] AND Billing Status = [Billed, Not Ready To Bill,Ready To Bill]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Billing Review Required] AND Billing Status = [Billed, Not Ready To Bill,Ready To Bill] AND Sample Status = [Received]"),
				new TemplateRow("•", "Billing Review Required", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Billing Review Required] AND Billing Status = [Billed, Not Ready To Bill,Ready To Bill] AND Sample Status = [Received]"),
				new TemplateRow("3", "Unbilled", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Entered] AND Billed/Not = [UnBilled]"),
				new TemplateRow("4", "Client Bill", "Resulted / Not = [Resulted] AND Payment Method = [Client Bill] AND Claim Status = [Billed,Not Entered in AMD] AND Billed/Not = [Billed,UnBilled] AND Client Status = [Client Bill] AND Billing Status = [Billed]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Payment Method = [Client Bill] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Client Bill] AND Billing Status = [Billed]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Payment Method = [Client Bill] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Client Bill] AND Billing Status = [Billed]"),
				new TemplateRow("5", "Self Pay", "Resulted / Not = [Resulted] AND Payment Method = [Self Pay] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [Self Pay] AND Billing Status = [Billed, Not Ready To Bill ]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Payment Method = [Self Pay] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Self Pay] AND Billing Status = [Billed, Not Ready To Bill ]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Payment Method = [Self Pay] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Self Pay] AND Billing Status = [Billed]"),
				new TemplateRow("•", "Entered", "Resulted / Not = [Resulted] AND Payment Method = [Self Pay] AND Claim Status = [Entered] AND Billed/Not = [UnBilled] AND Client Status = [Self Pay] AND Billing Status = [Billed]"),
				new TemplateRow("6", "Test Entries", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Test Entries] AND Billing Status = [Billed]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Test Entries] AND Billing Status = [Billed]"),
				new TemplateRow("7", "Billing Status - No Bill", "Resulted / Not = [Resulted] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [ALL] AND Billing Status = [No Bill]"),
				new TemplateRow("•", "Rejected", "Resulted / Not = [Resulted] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [ALL] AND Billing Status = [No Bill] AND Order Status = [Rejected]"),
				new TemplateRow("•", "Completed", "Resulted / Not = [Resulted] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [ALL] AND Billing Status = [No Bill] AND Order Status = [Completed]"),
				new TemplateRow("•", "Recollect Required", "Resulted / Not = [Resulted] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [ALL] AND Billing Status = [No Bill] AND Order Status = [Recollect Required]"),
				new TemplateRow("B", "Not Resulted", "Resulted / Not = [Not Resulted]"),
				new TemplateRow("1", "Not Entered in AMD", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD]"),
				new TemplateRow("•", "Collected", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Sample Status = [Collected]"),
				new TemplateRow("2", "Rejected Sample", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Sample Status = [Rejected]"),
			},
		["Rising Tides"] = new[] {
				new TemplateRow("", "Total Samples", "Count [Unique Sample ID]"),
				new TemplateRow("A", "Billable Samples - Resulted", "Resulted / Not = [Resulted]"),
				new TemplateRow("1", "Billed to Insurance", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Billed]"),
				new TemplateRow("•", "Billed In AMD", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Billed] AND Billed/Not = [Billed]"),
				new TemplateRow("2", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required, Blank] AND Payment Method = [Insurance] AND Billing Status != [No Bill]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required, Blank] AND Payment Method = [Insurance] AND Billing Status != [No Bill] AND Sample Status = [Received]"),
				new TemplateRow("•", "Billing Review Required", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Billing Review Required, Blank] AND Payment Method = [Insurance] AND Billing Status != [No Bill]"),
				new TemplateRow("3", "Unbilled", "Resulted / Not = [Resulted] AND Payment Method = [Insurance] AND Claim Status = [Entered] AND Billed/Not = [UnBilled]"),
				new TemplateRow("4", "Client Bill", "Resulted / Not = [Resulted] AND Payment Method = [Client Bill] AND Claim Status = [Billed, Not Entered in AMD] AND Billed/Not = [Billed, UnBilled] AND Client Status = [Client Bill] AND Billing Status != [No Bill]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Payment Method = [Client Bill] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Client Bill] AND Billing Status != [No Bill]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Payment Method = [Client Bill] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Client Bill] AND Billing Status != [No Bill]"),
				new TemplateRow("5", "Self Pay", "Resulted / Not = [Resulted] AND Payment Method = [Self Pay] AND Claim Status = [ALL] AND Billed/Not = [ALL] AND Client Status = [Self Pay] AND Billing Status != [No Bill]"),
				new TemplateRow("•", "Billed", "Resulted / Not = [Resulted] AND Payment Method = [Self Pay] AND Claim Status = [Billed] AND Billed/Not = [Billed] AND Client Status = [Self Pay] AND Billing Status != [No Bill]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Payment Method = [Self Pay] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Self Pay] AND Billing Status != [No Bill]"),
				new TemplateRow("•", "Entered", "Resulted / Not = [Resulted] AND Payment Method = [Self Pay] AND Claim Status = [Entered] AND Billed/Not = [UnBilled] AND Client Status = [Self Pay] AND Billing Status != [No Bill]"),
				new TemplateRow("6", "Test Entries", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Test Entries] AND Billing Status != [No Bill]"),
				new TemplateRow("•", "Not Entered in AMD", "Resulted / Not = [Resulted] AND Claim Status = [Not Entered in AMD] AND Billed/Not = [UnBilled] AND Client Status = [Test Entries] AND Billing Status != [No Bill]"),
				new TemplateRow("7", "Billing Status - No Bill", "Resulted / Not = [Resulted] AND Billing Status = [No Bill]"),
				new TemplateRow("•", "Rejected", "Resulted / Not = [Resulted] AND Billing Status = [No Bill] AND Order Status = [Rejected]"),
				new TemplateRow("•", "Completed", "Resulted / Not = [Resulted] AND Billing Status = [No Bill] AND Order Status = [Completed]"),
				new TemplateRow("•", "Recollect Required", "Resulted / Not = [Resulted] AND Billing Status = [No Bill] AND Order Status = [Recollect Required]"),
				new TemplateRow("B", "Not Resulted", "Resulted / Not = [Not Resulted]"),
				new TemplateRow("1", "Not Entered in AMD", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank]"),
				new TemplateRow("•", "Collected", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank] AND Sample Status = [Collected]"),
				new TemplateRow("•", "Received", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Blank] AND Sample Status = [Received]"),
				new TemplateRow("2", "Rejected Sample", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Rejected Sample]"),
				new TemplateRow("3", "Client Bill", "Resulted / Not = [Not Resulted] AND Claim Status = [Not Entered in AMD] AND Client Status = [Client Bill]"),
			},
	};

	public async Task<LisSummaryResult> GetLisSummaryAsync(
		string connectionString,
		string labName,
		int? labId = null,
		DateOnly? collectedFrom = null,
		DateOnly? collectedTo = null,
		CancellationToken ct = default)
	{
		ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

		await using var conn = new SqlConnection(connectionString);
		await conn.OpenAsync(ct);

		var columns = await GetLimsMasterColumnsAsync(conn, ct);
		if (columns.Count == 0)
		{
			throw new InvalidOperationException("dbo.LIMSMaster was not found, or no columns were found in dbo.LIMSMaster.");
		}

		var profile = ResolveProfile(labName, labId, columns);
		var sourceFileName = await GetLatestSourceFileNameAsync(conn, columns, ct);
		var raw = await LoadDynamicGroupsAsync(conn, profile, collectedFrom, collectedTo, ct);

		var months = raw
			.Select(x => $"{x.CollectedYear:D4}-{x.CollectedMonth:D2}")
			.Distinct()
			.OrderBy(x => x)
			.ToList();

		var years = months
			.Select(x => int.Parse(x[..4]))
			.Distinct()
			.OrderBy(x => x)
			.ToList();

		var rows = SheetTemplates.ContainsKey(profile.LogicSheetName)
			? BuildTemplatePivotRows(profile.LogicSheetName, raw)
			: BuildDynamicPivotRows(raw);

		var grandByMonth = raw
			.GroupBy(x => $"{x.CollectedYear:D4}-{x.CollectedMonth:D2}")
			.ToDictionary(g => g.Key, g => g.Sum(x => x.TotalClaims));

		var grandByYear = raw
			.GroupBy(x => x.CollectedYear)
			.ToDictionary(g => g.Key, g => g.Sum(x => x.TotalClaims));

		var kpiCards = BuildKpiCards(raw, grandByMonth.Values.Sum());

		return new LisSummaryResult(
			profile.LogicSheetName,
			sourceFileName,
			months,
			years,
			rows,
			grandByMonth,
			grandByYear,
			grandByMonth.Values.Sum(),
			kpiCards);
	}

	private static async Task<HashSet<string>> GetLimsMasterColumnsAsync(SqlConnection conn, CancellationToken ct)
	{
		const string sql = """
            SELECT COLUMN_NAME
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE TABLE_SCHEMA = 'dbo'
              AND TABLE_NAME = 'LIMSMaster';
            """;

		var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
		await using var reader = await cmd.ExecuteReaderAsync(ct);
		while (await reader.ReadAsync(ct))
		{
			columns.Add(reader.GetString(0));
		}

		return columns;
	}

	private static async Task<string> GetLatestSourceFileNameAsync(
		SqlConnection conn,
		HashSet<string> columns,
		CancellationToken ct)
	{
		if (!columns.Contains("SourceFile") || !columns.Contains("CreatedOn"))
		{
			return string.Empty;
		}

		const string sql = """
            SELECT TOP 1 SourceFile
            FROM dbo.LIMSMaster WITH (NOLOCK)
            ORDER BY CreatedOn DESC;
            """;

		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 60 };
		var value = await cmd.ExecuteScalarAsync(ct);
		return value == null || value == DBNull.Value
			? string.Empty
			: Convert.ToString(value)?.Trim() ?? string.Empty;
	}

	private static DimensionProfile ResolveProfile(string labName, int? labId, HashSet<string> columns)
	{
		var logicSheet = ResolveLogicSheet(labName, labId);
		var dateColumn = FirstExisting(columns, DateCandidatesFor(logicSheet))
			?? FirstExisting(columns,
				"RequestCollectDate", "ReqCollectDate", "DateOfCollection", "Entry_DateCreated",
				"ReceivedDate", "CollectionDate", "CollectedDate", "Collection_Date", "DOS")
			?? throw new InvalidOperationException("No usable collected-date column was found in dbo.LIMSMaster.");

		var fields = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
		{
			["Resulted / Not"] = FirstExisting(columns, ResultCandidatesFor(logicSheet)),
			["Result Status"] = FirstExisting(columns, ResultCandidatesFor(logicSheet)),
			["ResultedStatus"] = FirstExisting(columns, ResultCandidatesFor(logicSheet)),
			["Claim Status"] = FirstExisting(columns, ClaimStatusCandidatesFor(logicSheet)),
			["NA"] = FirstExisting(columns, "NA"),
			["Bill Status"] = FirstExisting(columns, BillStatusCandidatesFor(logicSheet)),
			["Billing Status"] = FirstExisting(columns, BillStatusCandidatesFor(logicSheet)),
			["Billed/Not"] = FirstExisting(columns, BillCategoryCandidatesFor(logicSheet)),
			["BilledOrNot"] = FirstExisting(columns, BillCategoryCandidatesFor(logicSheet)),
			["Bill To"] = FirstExisting(columns, BillToCandidatesFor(logicSheet)),
			["Payment Method"] = FirstExisting(columns, PaymentCandidatesFor(logicSheet)),
			["Client Status"] = FirstExisting(columns, ClientStatusCandidatesFor(logicSheet)),
			["Client Status 2"] = FirstExisting(columns, ClientStatus2CandidatesFor(logicSheet)),
			["Final Status"] = FirstExisting(columns, FinalStatusCandidatesFor(logicSheet)),
			["Final Status 2"] = FirstExisting(columns, FinalStatus2CandidatesFor(logicSheet)),
			["Sample Status"] = FirstExisting(columns, SampleStatusCandidatesFor(logicSheet)),
			["Order Status"] = FirstExisting(columns, OrderStatusCandidatesFor(logicSheet)),
			["Entry Status"] = FirstExisting(columns, EntryStatusCandidatesFor(logicSheet)),
			["Panel Type"] = FirstExisting(columns, PanelTypeCandidatesFor(logicSheet)),
			["Sub Status"] = FirstExisting(columns, SubStatusCandidatesFor(logicSheet)),
			["LRN Sample Status"] = FirstExisting(columns, SampleStatusCandidatesFor(logicSheet)),
			["LRN Bill Category"] = FirstExisting(columns, BillCategoryCandidatesFor(logicSheet)),
			["LRN Sub Status"] = FirstExisting(columns, SubStatusCandidatesFor(logicSheet)),
			["Source"] = FirstExisting(columns, SourceCandidatesFor(logicSheet)),
			["Charges not entered status"] = FirstExisting(columns, ChargesNotEnteredCandidatesFor(logicSheet)),
			["Insurance category"] = FirstExisting(columns, InsuranceCategoryCandidatesFor(logicSheet))
		};

		if (logicSheet.Equals("Augustus", StringComparison.OrdinalIgnoreCase))
		{
			fields = new Dictionary<string, string?>(StringComparer.OrdinalIgnoreCase)
			{
				["Billing Status"] = FirstExisting(columns, "BillingStatus", "Billing Status"),
				["Bill To"] = FirstExisting(columns, "BillTo", "Bill To"),
				["Result Status"] = FirstExisting(columns, "ResultStatus", "Result Status"),
				["Final Status"] = FirstExisting(columns, "FinalStatus", "Final Status"),
				["Client Status"] = FirstExisting(columns, "ClientStatus", "Client Status"),
				["Client Status 2"] = FirstExisting(columns, "ClientStatus2", "Client Status 2", "ClientStatus", "Client Status")
			};
		}

		var countDistinctColumn = FirstExisting(columns, CountDistinctCandidatesFor(logicSheet));
		var incorrectDosColumn = FirstExisting(columns, IncorrectDosCandidatesFor(logicSheet));

		return new DimensionProfile(logicSheet, dateColumn, countDistinctColumn, incorrectDosColumn, fields);
	}

	private static async Task<List<RawLisGroup>> LoadDynamicGroupsAsync(
		SqlConnection conn,
		DimensionProfile profile,
		DateOnly? collectedFrom,
		DateOnly? collectedTo,
		CancellationToken ct)
	{
		var dateExpr = $"TRY_CONVERT(date, {Q(profile.DateColumn)})";
		var where = new List<string>
		{
			$"{dateExpr} IS NOT NULL",
			$"YEAR({dateExpr}) > 1900"
		};

		var parameters = new List<SqlParameter>();
		if (collectedFrom.HasValue)
		{
			where.Add($"{dateExpr} >= @fromDate");
			parameters.Add(new SqlParameter("@fromDate", SqlDbType.Date) { Value = collectedFrom.Value.ToDateTime(TimeOnly.MinValue) });
		}

		if (collectedTo.HasValue)
		{
			where.Add($"{dateExpr} <= @toDate");
			parameters.Add(new SqlParameter("@toDate", SqlDbType.Date) { Value = collectedTo.Value.ToDateTime(TimeOnly.MinValue) });
		}

		if (RequiresBlankIncorrectDos(profile.LogicSheetName) && !string.IsNullOrWhiteSpace(profile.IncorrectDosColumn))
		{
			where.Add($"{TextExpr(profile.IncorrectDosColumn)} = ''");
		}

		var fieldList = profile.FieldColumns.Keys.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
		var selectDimensions = fieldList
			.Select(f => TextExpr(profile.FieldColumns[f], FieldAlias(f)))
			.ToList();

		var groupByDimensions = profile.FieldColumns.Values
			.Where(c => !string.IsNullOrWhiteSpace(c))
			.Distinct(StringComparer.OrdinalIgnoreCase)
			.Select(c => TextExpr(c))
			.ToList();

		var groupBy = groupByDimensions
			.Concat(new[] { $"YEAR({dateExpr})", $"MONTH({dateExpr})" })
			.ToList();

		var countExpr = !string.IsNullOrWhiteSpace(profile.CountDistinctColumn)
			? ShouldUseDistinctSampleCount(profile.LogicSheetName)
				? $"COUNT(DISTINCT NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), {Q(profile.CountDistinctColumn)}))), ''))"
				: $"COUNT(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), {Q(profile.CountDistinctColumn)}))), ''))"
			: "COUNT(*)";

		var sql = $"""
            SELECT
                {string.Join("," + Environment.NewLine + "                ", selectDimensions)},
                YEAR({dateExpr}) AS CollectedYear,
                MONTH({dateExpr}) AS CollectedMonth,
                {countExpr} AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                {string.Join("," + Environment.NewLine + "                ", groupBy)}
            ORDER BY CollectedYear, CollectedMonth;
            """;

		var raw = new List<RawLisGroup>();
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 240 };
		foreach (var p in parameters) cmd.Parameters.Add(p);

		await using var rdr = await cmd.ExecuteReaderAsync(ct);
		while (await rdr.ReadAsync(ct))
		{
			var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
			for (var i = 0; i < fieldList.Count; i++)
			{
				fields[fieldList[i]] = NormalizeFieldValue(fieldList[i], rdr.GetString(i));
			}

			raw.Add(new RawLisGroup(
				fields,
				rdr.GetInt32(fieldList.Count),
				rdr.GetInt32(fieldList.Count + 1),
				rdr.GetInt32(fieldList.Count + 2)));
		}

		return raw;
	}

	private static LisSummaryKpiCards BuildKpiCards(List<RawLisGroup> raw, int totalSamples)
	{
		var billedCount = raw
			.Where(x => IsBilledStatus(GetField(x, "Billing Status"))
				|| IsBilledStatus(GetField(x, "Bill Status"))
				|| IsBilledStatus(GetField(x, "Billed/Not")))
			.Sum(x => x.TotalClaims);

		var unbilledCount = raw
			.Where(x => IsUnbilledStatus(GetField(x, "Billing Status"))
				|| IsUnbilledStatus(GetField(x, "Bill Status"))
				|| IsUnbilledStatus(GetField(x, "Billed/Not")))
			.Sum(x => x.TotalClaims);

		var selfPayCount = raw
			.Where(x => IsSelfPay(GetField(x, "Bill To"))
				|| IsSelfPay(GetField(x, "Payment Method"))
				|| IsSelfPay(GetField(x, "Client Status")))
			.Sum(x => x.TotalClaims);

		return new LisSummaryKpiCards(totalSamples, billedCount, unbilledCount, selfPayCount);
	}

	private static bool IsBilledStatus(string? value)
	{
		var key = CompareKey(value);
		return key is "BILLED" or "SUBMITTED" or "CLAIMSUBMITTED"
			|| key.Contains("BILLED", StringComparison.OrdinalIgnoreCase) && !IsUnbilledStatus(value)
			|| key.Contains("SUBMITTED", StringComparison.OrdinalIgnoreCase);
	}

	private static bool IsUnbilledStatus(string? value)
	{
		var key = CompareKey(value);
		return key.Contains("UNBILL", StringComparison.OrdinalIgnoreCase)
			|| key.Contains("NOTBILL", StringComparison.OrdinalIgnoreCase)
			|| key.Contains("NOBILL", StringComparison.OrdinalIgnoreCase)
			|| key.Contains("PENDINGBILL", StringComparison.OrdinalIgnoreCase);
	}

	private static bool IsSelfPay(string? value)
	{
		var key = CompareKey(value);
		return key.Contains("SELFPAY", StringComparison.OrdinalIgnoreCase)
			|| key.Contains("PATIENTPAY", StringComparison.OrdinalIgnoreCase);
	}

	private static List<LisSummaryRow> BuildTemplatePivotRows(string logicSheetName, List<RawLisGroup> raw)
	{
		var rows = new List<LisSummaryRow>();
		if (!SheetTemplates.TryGetValue(logicSheetName, out var templateRows)) return BuildDynamicPivotRows(raw);

		foreach (var template in templateRows)
		{
			var matches = IsAugustusReadyToBillRow(logicSheetName, template)
				? raw.Where(x => MatchesTemplateLogic(x, AugustusReadyToBillCountLogic)).ToList()
				: IsTotalLogic(template.Logic)
				? raw
				: raw.Where(x => MatchesTemplateLogic(x, template.Logic)).ToList();

			rows.Add(BuildRow(template.Code, template.Description, template.Logic, ResolveTemplateLevel(logicSheetName, template), matches.ToList()));
		}

		if (!UsesDirectTemplateParentCounts(logicSheetName))
		{
			RecalculateParentRowsFromChildren(rows);
		}

		return rows;
	}

	private const string AugustusReadyToBillCountLogic = "Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status =  Resulted yet to be billed";

	private static bool IsAugustusReadyToBillRow(string logicSheetName, TemplateRow template)
		=> logicSheetName.Equals("Augustus", StringComparison.OrdinalIgnoreCase)
		   && template.Description.Equals("Ready to bill", StringComparison.OrdinalIgnoreCase);

	private static bool UsesDirectTemplateParentCounts(string logicSheetName)
		=> logicSheetName.Equals("Augustus", StringComparison.OrdinalIgnoreCase)
		   || logicSheetName.Equals("Beech Tree", StringComparison.OrdinalIgnoreCase)
		   || logicSheetName.Equals("Cove", StringComparison.OrdinalIgnoreCase)
		   || logicSheetName.Equals("PhiLife", StringComparison.OrdinalIgnoreCase)
		   || logicSheetName.Equals("Elixir", StringComparison.OrdinalIgnoreCase)
		   || logicSheetName.Equals("Rising Tides", StringComparison.OrdinalIgnoreCase)
		   || logicSheetName.Equals("PCRLOA", StringComparison.OrdinalIgnoreCase)
		   || logicSheetName.Equals("InHealth", StringComparison.OrdinalIgnoreCase);

	private static bool ShouldUseDistinctSampleCount(string logicSheetName)
		=> logicSheetName.Equals("PCRLOA", StringComparison.OrdinalIgnoreCase);

	private static void RecalculateParentRowsFromChildren(List<LisSummaryRow> rows)
	{
		for (var index = rows.Count - 1; index >= 0; index--)
		{
			var childRows = GetImmediateChildren(rows, index);
			if (childRows.Count == 0) continue;

			rows[index] = BuildChildAggregateRow(rows[index], childRows);
		}
	}

	private static List<LisSummaryRow> GetImmediateChildren(List<LisSummaryRow> rows, int parentIndex)
	{
		var parentLevel = rows[parentIndex].Level;
		var childLevel = parentLevel + 1;
		var children = new List<LisSummaryRow>();

		for (var index = parentIndex + 1; index < rows.Count && rows[index].Level > parentLevel; index++)
		{
			if (rows[index].Level == childLevel)
			{
				children.Add(rows[index]);
			}
		}

		return children;
	}

	private static LisSummaryRow BuildChildAggregateRow(LisSummaryRow parent, List<LisSummaryRow> children)
	{
		var byMonth = SumChildMonths(children);
		var byYear = SumChildYears(children);

		return new LisSummaryRow
		{
			Code = parent.Code,
			Description = parent.Description,
			Logic = parent.Logic,
			Level = parent.Level,
			ByMonth = byMonth,
			ByYear = byYear,
			Total = children.Sum(x => x.Total)
		};
	}

	private static Dictionary<string, int> SumChildMonths(List<LisSummaryRow> children)
		=> children
			.SelectMany(x => x.ByMonth)
			.GroupBy(x => x.Key, StringComparer.OrdinalIgnoreCase)
			.ToDictionary(g => g.Key, g => g.Sum(x => x.Value), StringComparer.OrdinalIgnoreCase);

	private static Dictionary<int, int> SumChildYears(List<LisSummaryRow> children)
		=> children
			.SelectMany(x => x.ByYear)
			.GroupBy(x => x.Key)
			.ToDictionary(g => g.Key, g => g.Sum(x => x.Value));

	private static bool MatchesTemplateLogic(RawLisGroup row, string logic)
	{
		foreach (var condition in SplitConditions(logic))
		{
			if (!TryParseCondition(condition, out var fieldName, out var expectedText, out var negate)) continue;

			var field = CanonicalFieldName(fieldName);
			var expectedValues = ParseExpectedValues(expectedText);
			if (expectedValues.Count == 0 || expectedValues.Any(v => IsAllValue(v))) continue;

			var actual = GetField(row, field);
			var matches = expectedValues.Any(v => ValueMatches(field, actual, v));
			if (negate ? matches : !matches) return false;
		}

		return true;
	}

	private static bool TryParseCondition(string condition, out string field, out string expectedText, out bool negate)
	{
		foreach (var op in new[] { " NOT EQUAL TO ", "!=", "<>" })
		{
			var index = condition.IndexOf(op, StringComparison.OrdinalIgnoreCase);
			if (index >= 0)
			{
				field = condition[..index].Trim();
				expectedText = condition[(index + op.Length)..].Trim();
				negate = true;
				return true;
			}
		}

		var equalsIndex = condition.IndexOf('=', StringComparison.Ordinal);
		if (equalsIndex >= 0)
		{
			field = condition[..equalsIndex].Trim();
			expectedText = condition[(equalsIndex + 1)..].Trim();
			negate = false;
			return true;
		}

		field = string.Empty;
		expectedText = string.Empty;
		negate = false;
		return false;
	}

	private static List<string> SplitConditions(string logic)
	{
		var result = new List<string>();
		var start = 0;
		var bracketDepth = 0;
		for (var i = 0; i < logic.Length; i++)
		{
			if (logic[i] == '[') bracketDepth++;
			else if (logic[i] == ']' && bracketDepth > 0) bracketDepth--;

			if (bracketDepth == 0
				&& i + 5 <= logic.Length
				&& string.Compare(logic, i, " AND ", 0, 5, StringComparison.OrdinalIgnoreCase) == 0)
			{
				result.Add(logic[start..i].Trim());
				i += 4;
				start = i + 1;
			}
		}

		result.Add(logic[start..].Trim());
		return result.Where(ContainsConditionOperator).ToList();
	}

	private static bool ContainsConditionOperator(string condition)
		=> condition.Contains('=', StringComparison.Ordinal)
		   || condition.Contains("!=", StringComparison.Ordinal)
		   || condition.Contains("<>", StringComparison.Ordinal)
		   || condition.Contains(" NOT EQUAL TO ", StringComparison.OrdinalIgnoreCase);

	private static List<string> ParseExpectedValues(string valueText)
	{
		var cleaned = valueText.Trim().Trim('[', ']').Trim();
		if (string.IsNullOrWhiteSpace(cleaned)) return new List<string>();

		return cleaned
			.Split(new[] { ",", " AND " }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
			.Where(x => !string.IsNullOrWhiteSpace(x))
			.ToList();
	}

	private static string GetField(RawLisGroup row, string field)
	{
		if (row.Fields.TryGetValue(field, out var value) && !string.IsNullOrWhiteSpace(value)) return value;

		return field switch
		{
			"Billing Status" => FirstNonBlank(ValueOrBlank(row, "Billing Status"), ValueOrBlank(row, "Bill Status"), ValueOrBlank(row, "Billed/Not")),
			"Bill Status" => FirstNonBlank(ValueOrBlank(row, "Bill Status"), ValueOrBlank(row, "Billing Status"), ValueOrBlank(row, "Billed/Not")),
			"Billed/Not" => FirstNonBlank(ValueOrBlank(row, "Billed/Not"), ValueOrBlank(row, "Billing Status"), ValueOrBlank(row, "Bill Status")),
			"Bill To" => FirstNonBlank(ValueOrBlank(row, "Bill To"), ValueOrBlank(row, "Payment Method")),
			"Payment Method" => FirstNonBlank(ValueOrBlank(row, "Payment Method"), ValueOrBlank(row, "Bill To")),
			"Client Status" => FirstNonBlank(ValueOrBlank(row, "Client Status"), ValueOrBlank(row, "Client Status 2")),
			"Client Status 2" => FirstNonBlank(ValueOrBlank(row, "Client Status 2"), ValueOrBlank(row, "Client Status")),
			"Final Status 2" => FirstNonBlank(ValueOrBlank(row, "Final Status 2"), ValueOrBlank(row, "Final Status"), ValueOrBlank(row, "Claim Status")),
			"Final Status" => FirstNonBlank(ValueOrBlank(row, "Final Status"), ValueOrBlank(row, "Claim Status")),
			"Sub Status" => FirstNonBlank(ValueOrBlank(row, "Sub Status"), ValueOrBlank(row, "Client Status"), ValueOrBlank(row, "Sample Status")),
			"Panel Type" => FirstNonBlank(ValueOrBlank(row, "Panel Type"), ValueOrBlank(row, "Sample Status")),
			_ => string.Empty
		};
	}

	private static string ValueOrBlank(RawLisGroup row, string field)
		=> row.Fields.TryGetValue(field, out var value) ? value : string.Empty;

	private static bool ValueMatches(string field, string actual, string expected)
	{
		if (IsBlankValue(expected)) return string.IsNullOrWhiteSpace(actual);
		if (IsAllValue(expected)) return true;

		var actualClean = CleanValue(actual);
		var expectedClean = CleanValue(expected);
		if (actualClean.Equals(expectedClean, StringComparison.OrdinalIgnoreCase)) return true;

		var actualKey = CompareKey(actual);
		var expectedKey = CompareKey(expected);
		if (actualKey == expectedKey) return true;
		if (string.IsNullOrWhiteSpace(actualKey) || string.IsNullOrWhiteSpace(expectedKey)) return false;

		if (IsBillStatusField(field))
		{
			var actualStatusKey = CompareKey(NormalizeBillStatus(actual));
			var expectedStatusKey = CompareKey(NormalizeBillStatus(expected));
			if (IsCanonicalBillStatusKey(actualStatusKey)
				&& IsCanonicalBillStatusKey(expectedStatusKey)
				&& actualStatusKey == expectedStatusKey)
			{
				return true;
			}
		}

		// Allow small wording differences used by the lab templates, e.g. Insurance Bill(s), Selfpay/Self Pay.
		return actualKey.TrimEnd('S') == expectedKey.TrimEnd('S')
			   || actualKey.TrimEnd('D') == expectedKey.TrimEnd('D');
	}

	private static bool IsBillStatusField(string field)
	{
		var canonical = CanonicalFieldName(field);
		return canonical is "Billing Status" or "Bill Status" or "Billed/Not";
	}

	private static bool IsCanonicalBillStatusKey(string key)
		=> key is "BILLED" or "UNBILLED" or "NONBILLABLE";

	private static bool IsAllValue(string value)
		=> CompareKey(value) == "ALL";

	private static bool IsBlankValue(string value)
		=> CompareKey(value) is "BLANK" or "NULL" or "EMPTY";

	private static bool IsTotalLogic(string logic)
	{
		var key = CompareKey(logic);
		return key.Contains("TOTALSAMPLES", StringComparison.OrdinalIgnoreCase)
			   || key.StartsWith("COUNTUNIQUE", StringComparison.OrdinalIgnoreCase)
			   || key == "COUNTORDERID";
	}

	private static int ResolveTemplateLevel(string logicSheetName, TemplateRow template)
	{
		if (IsAugustusReadyToBillRow(logicSheetName, template)) return 3;
		if (IsCoveBillablePanelTypeRow(logicSheetName, template)) return 1;

		var c = CleanValue(template.Code);
		if (string.IsNullOrWhiteSpace(c)) return 0;
		if (c is "•" or "◦") return 2;
		if (c is "•" or "◦") return 2;
		if (c is "•" or "◦" or "*") return 2;
		if (int.TryParse(c, out _)) return 1;
		return 0;
	}

	private static bool IsCoveBillablePanelTypeRow(string logicSheetName, TemplateRow template)
		=> logicSheetName.Equals("Cove", StringComparison.OrdinalIgnoreCase)
		   && template.Logic.Contains("Final Status = [Billable]", StringComparison.OrdinalIgnoreCase)
		   && template.Logic.Contains("Panel Type =", StringComparison.OrdinalIgnoreCase);

	private static List<LisSummaryRow> BuildDynamicPivotRows(List<RawLisGroup> raw)
	{
		var rows = new List<LisSummaryRow>
		{
			BuildRow("A", "Total Samples", "All rows from dbo.LIMSMaster for the selected collected-date range", 0, raw)
		};

		AddDimensionRows(rows, raw, "Result Status", x => GetField(x, "Resulted / Not"), "Result Status", 1);
		AddNestedRows(rows, raw, "Bill To / Payment Type", x => GetField(x, "Bill To"), "Billed Status", x => GetField(x, "Billing Status"), "B");
		AddNestedRows(rows, raw, "Final / Client Status", x => GetField(x, "Final Status"), "Sample / Category", x => GetField(x, "Sample Status"), "C");

		RecalculateParentRowsFromChildren(rows);
		return rows;
	}

	private static void AddDimensionRows(List<LisSummaryRow> rows, List<RawLisGroup> raw, string sectionDescription, Func<RawLisGroup, string> selector, string logicLabel, int level)
	{
		var groups = raw.GroupBy(x => DisplayValue(selector(x))).Where(g => !string.IsNullOrWhiteSpace(g.Key)).OrderByDescending(g => g.Sum(x => x.TotalClaims)).ThenBy(g => g.Key).ToList();
		if (groups.Count == 0) return;
		rows.Add(BuildRow("B", sectionDescription, $"Dynamic group by {logicLabel}", 0, raw));
		var index = 1;
		foreach (var group in groups)
		{
			rows.Add(BuildRow(index.ToString(), group.Key, $"{logicLabel} = {group.Key}", level, group.ToList()));
			index++;
		}
	}

	private static void AddNestedRows(List<LisSummaryRow> rows, List<RawLisGroup> raw, string parentTitle, Func<RawLisGroup, string> parentSelector, string childTitle, Func<RawLisGroup, string> childSelector, string startCode)
	{
		var parentGroups = raw.GroupBy(x => DisplayValue(parentSelector(x))).Where(g => !string.IsNullOrWhiteSpace(g.Key)).OrderByDescending(g => g.Sum(x => x.TotalClaims)).ThenBy(g => g.Key).ToList();
		if (parentGroups.Count == 0) return;
		rows.Add(BuildRow(startCode, parentTitle, $"Dynamic group by {parentTitle}", 0, raw));
		var parentIndex = 1;
		foreach (var parent in parentGroups)
		{
			var parentRows = parent.ToList();
			rows.Add(BuildRow(parentIndex.ToString(), parent.Key, $"{parentTitle} = {parent.Key}", 1, parentRows));
			var childGroups = parentRows.GroupBy(x => DisplayValue(childSelector(x))).Where(g => !string.IsNullOrWhiteSpace(g.Key) && !g.Key.Equals(parent.Key, StringComparison.OrdinalIgnoreCase)).OrderByDescending(g => g.Sum(x => x.TotalClaims)).ThenBy(g => g.Key).ToList();
			foreach (var child in childGroups)
			{
				rows.Add(BuildRow("•", child.Key, $"{parentTitle} = {parent.Key} AND {childTitle} = {child.Key}", 2, child.ToList()));
			}
			parentIndex++;
		}
	}

	private static LisSummaryRow BuildRow(string code, string description, string logic, int level, List<RawLisGroup> source)
	{
		var byMonth = source.GroupBy(x => $"{x.CollectedYear:D4}-{x.CollectedMonth:D2}").ToDictionary(g => g.Key, g => g.Sum(x => x.TotalClaims));
		var byYear = source.GroupBy(x => x.CollectedYear).ToDictionary(g => g.Key, g => g.Sum(x => x.TotalClaims));
		return new LisSummaryRow { Code = code, Description = description, Logic = logic, Level = level, ByMonth = byMonth, ByYear = byYear, Total = byMonth.Values.Sum() };
	}

	private static string TextExpr(string? columnName, string? alias = null)
	{
		var expr = string.IsNullOrWhiteSpace(columnName)
			? "CAST('' AS nvarchar(4000))"
			: $"ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), {Q(columnName)}))), ''), '')";
		return string.IsNullOrWhiteSpace(alias) ? expr : $"{expr} AS {Q(alias)}";
	}

	private static string FieldAlias(string fieldName) => "F_" + CompareKey(fieldName);
	private static string? FirstExisting(HashSet<string> columns, params string[] candidates) => candidates.FirstOrDefault(columns.Contains);
	private static string Q(string identifier) => $"[{identifier.Replace("]", "]]", StringComparison.Ordinal)}]";
	private static string DisplayValue(string? value) { var cleaned = CleanValue(value); return string.IsNullOrWhiteSpace(cleaned) ? "Blank / Unknown" : cleaned; }
	private static string CleanValue(string? value) => string.Join(' ', (value ?? string.Empty).Replace(' ', ' ').Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries));
	private static string CompareKey(string? value) => new string(CleanValue(value).ToUpperInvariant().Where(char.IsLetterOrDigit).ToArray());
	private static string FirstNonBlank(params string?[] values) => values.FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? string.Empty;

	private static string CanonicalFieldName(string field)
	{
		var key = CompareKey(field);
		return key switch
		{
			"RESULTEDNOT" or "RESULTEDORNOT" or "RESULTSTATUS" or "RESULTEDSTATUS" => "Resulted / Not",
			"CLAIMSTATUS" => "Claim Status",
			"BILLSTATUS" => "Bill Status",
			"BILLINGSTATUS" => "Billing Status",
			"BILLEDNOT" or "BILLEDORNOT" or "LRNBILLCATEGORY" => "Billed/Not",
			"BILLTO" => "Bill To",
			"PAYMENTMETHOD" => "Payment Method",
			"CLIENTSTATUS" => "Client Status",
			"CLIENTSTATUS2" => "Client Status 2",
			"FINALSTATUS" => "Final Status",
			"FINALSTATUS2" => "Final Status 2",
			"SUBSTATUS" or "SUBSTATUS2" or "LRNSUBSTATUS" => "Sub Status",
			"PANELTYPE" => "Panel Type",
			"SAMPLESTATUS" or "LRNSAMPLESTATUS" => "Sample Status",
			"ORDERSTATUS" => "Order Status",
			"ENTRYSTATUS" => "Entry Status",
			"SOURCE" => "Source",
			"CHARGESNOTENTEREDSTATUS" or "CHARGESNOTENTERED" => "Charges not entered status",
			"INSURANCECATEGORY" => "Insurance category",
			_ => field.Trim()
		};
	}

	private static string NormalizeFieldValue(string field, string? value)
	{
		var canonical = CanonicalFieldName(field);
		return canonical switch
		{
			"Resulted / Not" or "Result Status" or "ResultedStatus" => NormalizeResultStatus(value),
			"Bill Status" or "Billing Status" or "Billed/Not" or "BilledOrNot" => NormalizeBillStatus(value),
			"Bill To" => NormalizeBillTo(value),
			_ => CleanValue(value)
		};
	}

	private static string NormalizeResultStatus(string? value)
	{
		var cleaned = CleanValue(value);
		var key = CompareKey(cleaned);
		if (string.IsNullOrWhiteSpace(key)) return string.Empty;
		if (ContainsAny(key, "NOTRESULT", "PENDING", "INPROCESS", "PROCESSING", "RECEIVED", "ACCESSION", "HOLD")) return "Not Resulted";
		if (ContainsAny(key, "RESULT", "COMPLETE", "REPORTED", "FINAL")) return "Resulted";
		if (ContainsAny(key, "CANCEL", "REJECT")) return "Cancelled / Rejected";
		return cleaned;
	}

	private static string NormalizeBillStatus(string? value)
	{
		var cleaned = CleanValue(value);
		var key = CompareKey(cleaned);
		if (string.IsNullOrWhiteSpace(key)) return string.Empty;
		if (key == "NOBILL") return "No Bill";
		if (key.Contains("NOTREADYTOBILL", StringComparison.OrdinalIgnoreCase)) return "Not Ready To Bill";
		if (key.Contains("READYTOBILL", StringComparison.OrdinalIgnoreCase)) return "Ready To Bill";
		if (ContainsAny(key, "UNBILL", "NOTBILL", "PENDINGBILL")) return "Unbilled";
		if (ContainsAny(key, "BILLED", "SUBMITTED", "CHARGECREATED", "CLAIMCREATED")) return "Billed";
		if (ContainsAny(key, "NONBILL", "DONOTBILL", "EXCLUDED")) return "Non Billable";
		return cleaned;
	}

	private static string NormalizeBillTo(string? value)
	{
		var cleaned = CleanValue(value);
		var key = CompareKey(cleaned);
		if (string.IsNullOrWhiteSpace(key)) return string.Empty;
		if (ContainsAny(key, "INSURANCE", "INS", "PAYER")) return "Insurance Bill";
		if (ContainsAny(key, "SELFPAY", "PATIENT")) return "Self Pay";
		if (ContainsAny(key, "CLIENT")) return "Client Bill";
		if (ContainsAny(key, "VALIDATE", "UNKNOWN")) return "Yet to be Validated";
		return cleaned;
	}

	private static bool ContainsAny(string value, params string[] tokens) => tokens.Any(value.Contains);

	private static string ResolveLogicSheet(string labName, int? labId)
	{
		if (labId.HasValue)
		{
			return labId.Value switch
			{
				2 => "InHealth",
				4 => "Cove",
				7 => "PCRDx-AL",
				8 => "PCRDx-CO",
				13 => "PCRLOA",
				16 => "Elixir",
				18 => "Certus",
				19 => "Augustus",
				20 => "NWL",
				_ => ResolveLogicSheetByName(labName)
			};
		}
		return ResolveLogicSheetByName(labName);
	}

	private static string ResolveLogicSheetByName(string labName)
	{
		var n = CompareKey(labName);
		if (n.Contains("BEECH")) return "Beech Tree";
		if (n.Contains("NORTHWEST") || n.Contains("NWL")) return "NWL";
		if (n.Contains("AUGUSTUS")) return "Augustus";
		if (n.Contains("CERTUS")) return "Certus";
		if (n.Contains("PHILIFE")) return "PhiLife";
		if (n.Contains("RISINGTIDES") || n.Contains("RISING")) return "Rising Tides";
		if (n.Contains("COVE")) return "Cove";
		if (n.Contains("ELIXIR")) return "Elixir";
		if (n.Contains("INHEALTH")) return "InHealth";
		if (n.Contains("PCRDXAL") || n.Contains("PCRDXA")) return "PCRDx-AL";
		if (n.Contains("PCRDXCO") || n.Contains("PCRDXC")) return "PCRDx-CO";
		if (n.Contains("PCR")) return "PCRLOA";
		return "Dynamic";
	}

	private static string[] DateCandidatesFor(string logicSheet) => logicSheet switch
	{
		"Augustus" or "Certus" => new[] { "ReqCollectDate", "RequestCollectDate", "CollectionDate" },
		"Cove" or "Elixir" => new[] { "DateOfCollection", "RequestCollectDate", "CollectionDate" },
		"InHealth" => new[] { "Entry_DateCreated", "RequestCollectDate", "DateOfCollection" },
		"PCRDx-AL" => new[] { "ReceivedDate", "RequestCollectDate", "CollectionDate" },
		"PCRDx-CO" => new[] { "CollectionDate", "RequestCollectDate", "ReceivedDate" },
		_ => new[] { "RequestCollectDate", "ReqCollectDate", "DateOfCollection", "ReceivedDate", "CollectionDate", "Entry_DateCreated", "Collected" }
	};

	private static string[] CountDistinctCandidatesFor(string logicSheet) => logicSheet switch
	{
		"Beech Tree" => new[] { "Accession", "OrderID", "Order ID", "UniqueSampleID", "Unique Sample ID", "SampleID", "Sample ID", "AccessionNumber", "AccessionNo" },
		_ => new[] { "Accession", "OrderID", "Order ID", "UniqueSampleID", "Unique Sample ID", "SampleID", "Sample ID", "AccessionNumber", "AccessionNo", "SpecimenID", "Specimen ID" }
	};

	private static string[] IncorrectDosCandidatesFor(string logicSheet)
		=> new[] { "IncorrectDOS", "Incorrect DOS", "Incorrect_DOS", "IncorrectDos" };

	private static bool RequiresBlankIncorrectDos(string logicSheet)
		=> logicSheet is "Certus" or "NWL";

	private static string[] ResultCandidatesFor(string logicSheet) => logicSheet switch
	{
		"PCRDx-AL" => new[] { "LRNResultStatus", "ResultStatus", "RessultedStatus", "ResultedStatus" },
		_ => new[] { "RessultedStatus", "ResultedStatus", "ResultStatus", "LRNResultStatus", "ResultedNot", "Resulted_Not" }
	};
	private static string[] ClaimStatusCandidatesFor(string logicSheet) => logicSheet switch
	{
		"NWL" => new[] { "BillStatus", "FinalStatus", "ClaimStatus", "BillingStatus" },
		"Augustus" or "Certus" => new[] { "FinalStatus", "BillingStatus", "ClaimStatus" },
		"Cove" or "Elixir" => new[] { "NewStatus", "ClaimStatus", "FinalStatus" },
		"InHealth" => new[] { "SampleStatus", "SubStatus", "ClaimStatus" },
		"PCRDx-AL" => new[] { "LRNSampleStatus", "LRNBillCategory", "ClaimStatus" },
		"PCRDx-CO" => new[] { "LRNSampleStatus", "LRNSubStatus", "ClaimStatus" },
		_ => new[] { "ClaimStatus", "BillStatus", "FinalStatus", "BillingStatus", "NewStatus", "SampleStatus", "LRNSampleStatus" }
	};
	private static string[] BillStatusCandidatesFor(string logicSheet) => logicSheet switch
	{
		"NWL" => new[] { "BillStatus", "BillingStatus", "BilledorNot", "BillCategory" },
		_ => new[] { "BillingStatus", "BillStatus", "BilledorNot", "BillCategory", "LRNBillCategory" }
	};
	private static string[] BillCategoryCandidatesFor(string logicSheet) => logicSheet switch
	{
		"Augustus" or "Certus" => new[] { "BillingStatus", "BillCategory", "BilledorNot", "BillStatus" },
		"NWL" => new[] { "BillStatus", "BillingStatus", "BilledorNot", "BillCategory" },
		"Cove" or "Elixir" or "InHealth" => new[] { "BillCategory", "BilledorNot", "BillingStatus", "BillStatus" },
		"PCRDx-AL" or "PCRDx-CO" => new[] { "LRNBillCategory", "BillCategory", "BilledorNot" },
		_ => new[] { "BilledorNot", "BillCategory", "BillingStatus", "BillStatus", "LRNBillCategory" }
	};
	private static string[] BillToCandidatesFor(string logicSheet) => logicSheet switch
	{
		"NWL" => new[] { "BilledTo", "BillTo", "Bill To", "Billed To", "PaymentMethod", "InsuranceCategory" },
		"Augustus" or "Certus" => new[] { "BillTo", "Bill To", "BilledTo", "Billed To", "PaymentMethod", "InsuranceType" },
		_ => new[] { "BillTo", "Bill To", "BilledTo", "Billed To", "PaymentMethod", "InsuranceCategory", "InsuranceType", "BillToType" }
	};
	private static string[] PaymentCandidatesFor(string logicSheet) => logicSheet switch
	{
		"PCRLOA" => new[] { "InsuranceCategory", "PaymentMethod", "BillTo", "BilledTo", "InsuranceType" },
		"NWL" => new[] { "BilledTo", "BillTo", "Category", "PaymentMethod" },
		"Augustus" or "Certus" => new[] { "BillTo", "BilledTo", "PaymentMethod", "InsuranceType" },
		"Cove" or "Elixir" => new[] { "InsuranceType", "PaymentMethod", "BillTo", "BilledTo" },
		_ => new[] { "PaymentMethod", "InsuranceCategory", "InsuranceType", "BillTo", "BilledTo", "BillToType" }
	};
	private static string[] ClientStatusCandidatesFor(string logicSheet) => new[] { "ClientStatus", "Client Status", "SubStatus", "LRNSubStatus", "FinalStatus", "NewStatus" };
	private static string[] ClientStatus2CandidatesFor(string logicSheet) => new[] { "ClientStatus2", "Client Status 2", "ClientStatus", "SubStatus", "LRNSubStatus" };
	private static string[] FinalStatusCandidatesFor(string logicSheet) => logicSheet switch
	{
		"NWL" => new[] { "FinalStatus", "Final Status", "Category", "ClientStatus" },
		"Augustus" or "Certus" => new[] { "FinalStatus", "Final Status", "ResultStatus", "ClientStatus" },
		"Cove" or "Elixir" => new[] { "NewStatus", "FinalStatus", "ClientStatus" },
		"InHealth" => new[] { "SubStatus", "SampleStatus", "FinalStatus", "ClientStatus" },
		"PCRDx-CO" => new[] { "LRNSubStatus", "LRNSampleStatus", "FinalStatus", "ClientStatus" },
		"PCRDx-AL" => new[] { "LRNSampleStatus", "FinalStatus", "ClientStatus" },
		_ => new[] { "ClientStatus", "FinalStatus", "SubStatus", "NewStatus", "LRNSubStatus", "LRNSampleStatus" }
	};
	private static string[] FinalStatus2CandidatesFor(string logicSheet) => new[] { "FinalStatus2", "Final Status 2", "FinalStatus", "Category", "ClientStatus", "SubStatus" };
	private static string[] SampleStatusCandidatesFor(string logicSheet) => logicSheet switch
	{
		"NWL" => new[] { "Category", "SampleStatus", "SubStatus" },
		"PCRDx-AL" or "PCRDx-CO" => new[] { "LRNSampleStatus", "LRNSubStatus", "SampleStatus" },
		"InHealth" => new[] { "SampleStatus", "SubStatus" },
		_ => new[] { "SampleStatus", "Sample Status", "Category", "SubStatus", "LRNSampleStatus", "LRNSubStatus", "InsuranceType" }
	};
	private static string[] OrderStatusCandidatesFor(string logicSheet) => new[] { "OrderStatus", "Order Status", "SampleStatus", "LRNSampleStatus", "ClientStatus", "FinalStatus", "NewStatus" };
	private static string[] EntryStatusCandidatesFor(string logicSheet) => new[] { "EntryStatus", "Entry_Status", "Entry Status", "OrderStatus", "Order Status" };
	private static string[] PanelTypeCandidatesFor(string logicSheet) => new[] { "PanelType", "Panel Type" };
	private static string[] SubStatusCandidatesFor(string logicSheet) => new[] { "SubStatus", "Sub Status", "ClientStatus", "Client Status" };
	private static string[] SourceCandidatesFor(string logicSheet) => logicSheet switch
	{
		"NWL" => new[] { "SourceSystem", "SystemSource", "Source", "BillingSource", "Billing Source" },
		_ => new[] { "Source", "BillingSource", "Billing Source", "SystemSource", "SourceSystem" }
	};
	private static string[] ChargesNotEnteredCandidatesFor(string logicSheet) => new[] { "ChargesNotEnteredStatus", "Charges not entered status", "ChargesNotEntered", "Charges_Not_Entered_Status" };
	private static string[] InsuranceCategoryCandidatesFor(string logicSheet) => new[] { "InsuranceCategory", "Insurance category", "InsuranceType", "Category" };
}

