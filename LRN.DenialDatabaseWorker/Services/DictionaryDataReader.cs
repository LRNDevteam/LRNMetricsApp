using System;
using System.Collections.Generic;
using System.Data;

public sealed class DictionaryDataReader : IDataReader
{
	private readonly IEnumerator<Dictionary<string, string>> _enumerator;
	private readonly List<string> _columns;

	public DictionaryDataReader(IEnumerable<Dictionary<string, string>> rows, List<string> columns)
	{
		_enumerator = rows.GetEnumerator();
		_columns = columns;
	}

	public int FieldCount => _columns.Count;

	public bool Read() => _enumerator.MoveNext();

	public object GetValue(int i)
	{
		var col = _columns[i];
		if (_enumerator.Current.TryGetValue(col, out var v))
			return (object)v ?? DBNull.Value;

		return DBNull.Value;
	}

	public int GetValues(object[] values)
	{
		int count = Math.Min(values.Length, FieldCount);

		for (int i = 0; i < count; i++)
			values[i] = GetValue(i);

		return count;
	}

	public string GetName(int i) => _columns[i];

	public int GetOrdinal(string name) => _columns.IndexOf(name);

	public object this[int i] => GetValue(i);

	public object this[string name] => GetValue(GetOrdinal(name));

	// ---------------- UNUSED MEMBERS (REQUIRED BY INTERFACE) ----------------

	public void Dispose() => _enumerator.Dispose();
	public void Close() { }
	public bool NextResult() => false;
	public int Depth => 0;
	public bool IsClosed => false;
	public int RecordsAffected => -1;
	public DataTable GetSchemaTable() => null;

	public bool IsDBNull(int i) => GetValue(i) == DBNull.Value;

	public string GetDataTypeName(int i) => "nvarchar";
	public Type GetFieldType(int i) => typeof(string);

	public bool GetBoolean(int i) => Convert.ToBoolean(GetValue(i));
	public byte GetByte(int i) => Convert.ToByte(GetValue(i));

	public long GetBytes(int i, long fieldOffset, byte[] buffer, int bufferoffset, int length)
		=> throw new NotSupportedException();

	public char GetChar(int i) => Convert.ToChar(GetValue(i));

	public long GetChars(int i, long fieldoffset, char[] buffer, int bufferoffset, int length)
		=> throw new NotSupportedException();

	public IDataReader GetData(int i) => throw new NotSupportedException();

	public DateTime GetDateTime(int i) => Convert.ToDateTime(GetValue(i));
	public decimal GetDecimal(int i) => Convert.ToDecimal(GetValue(i));
	public double GetDouble(int i) => Convert.ToDouble(GetValue(i));
	public float GetFloat(int i) => Convert.ToSingle(GetValue(i));
	public Guid GetGuid(int i) => Guid.Parse(GetValue(i).ToString());
	public short GetInt16(int i) => Convert.ToInt16(GetValue(i));
	public int GetInt32(int i) => Convert.ToInt32(GetValue(i));
	public long GetInt64(int i) => Convert.ToInt64(GetValue(i));
	public string GetString(int i) => GetValue(i)?.ToString();
}