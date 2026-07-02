using System.Data;
using DenialDatabaseProcessorWorker.Models;

namespace DenialDatabaseProcessorWorker.BulkWriters;

public sealed class DenialTaskBoardBulkWriter : BulkWriterBase
{
	private static readonly TableMapperConfig Mapper = LoadMapper(@"MapperJon\DenialTaskBoardMapper.json");

	public DenialTaskBoardBulkWriter(string connectionString)
		: base(connectionString)
	{
	}

	public Task WriteAsync(DataTable table, LabConfig lab, string runId)
		=> BulkInsertAsync(table, Mapper.TargetTable, Mapper);
}