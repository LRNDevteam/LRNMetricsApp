using System.Data;
using DenialDatabaseProcessorWorker.Models;

namespace DenialDatabaseProcessorWorker.BulkWriters;

public sealed class DenialInsightBulkWriter : BulkWriterBase
{
	private static readonly TableMapperConfig Mapper = LoadMapper(@"MapperJon\DenialInsightMapper.json");

	public DenialInsightBulkWriter(string connectionString)
		: base(connectionString)
	{
	}

	public Task WriteAsync(DataTable table, LabConfig lab, string runId)
		=> BulkInsertAsync(table, Mapper.TargetTable, Mapper);
}