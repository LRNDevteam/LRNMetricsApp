using System.Collections.Generic;

namespace DenialDatabaseProcessorWorker.Services;

public sealed class TaskBoardMapper
{
	public string TargetTable { get; set; } = string.Empty;
	public List<TaskBoardColumnMap> Columns { get; set; } = new();
}

public sealed class TaskBoardColumnMap
{
	public string ExcelColumn { get; set; } = string.Empty;
	public string SqlColumn { get; set; } = string.Empty;
	public string DataType { get; set; } = string.Empty;
}