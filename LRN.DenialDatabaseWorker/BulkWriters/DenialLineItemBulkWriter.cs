using System.Data;
using DenialDatabaseProcessorWorker.Models;

namespace DenialDatabaseProcessorWorker.BulkWriters;

public sealed class DenialLineItemBulkWriter : BulkWriterBase
{
	private static readonly TableMapperConfig Mapper = LoadMapper(@"MapperJon\DenialLineItemMapper.json");

	public DenialLineItemBulkWriter(string connectionString)
		: base(connectionString)
	{
	}

	public Task WriteAsync(DataTable table, LabConfig lab, string runId)
		=> BulkInsertAsync(table, Mapper.TargetTable, Mapper);
}