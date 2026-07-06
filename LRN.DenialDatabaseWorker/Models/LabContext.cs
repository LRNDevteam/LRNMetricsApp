public sealed class LabContext
{
	public int LabId { get; }
	public string LabName { get; }
	public string RunId { get; }
	public string ConnectionString { get; }

	public LabContext(int labId, string labName, string runId, string connectionString)
	{
		LabId = labId;
		LabName = labName;
		RunId = runId;
		ConnectionString = connectionString;
	}
}

public sealed class TableMapperConfig
{
	public string TargetTable { get; set; } = string.Empty;
	public List<ColumnMapperConfig> Columns { get; set; } = new();
}

public sealed class ColumnMapperConfig
{
	public string ExcelColumn { get; set; } = string.Empty;
	public string SqlColumn { get; set; } = string.Empty;
	public string DataType { get; set; } = string.Empty;
}