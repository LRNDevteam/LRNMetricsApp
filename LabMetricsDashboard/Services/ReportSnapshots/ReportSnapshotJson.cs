using System.Text.Json;
using System.Text.Json.Serialization;

namespace LabMetricsDashboard.Services.ReportSnapshots;

/// <summary>
/// The JSON settings of a report snapshot's display copy (<c>..._&lt;REPORTCODE&gt;_PageModel.json.gz</c>).
/// LRN.SnapshotGenerator writes the page's view model with them and the snapshot viewer binds it back
/// to the same type, so both sides must use this one instance.
/// </summary>
public static class ReportSnapshotJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        ReferenceHandler = ReferenceHandler.IgnoreCycles,
        NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
        Converters = { new JsonStringEnumConverter(), new ValueTupleJsonConverterFactory() }
    };
}

/// <summary>
/// Value tuples, which System.Text.Json otherwise writes as <c>{}</c> (their elements are fields) and refuses
/// as dictionary keys: a value is a JSON array (<c>[2026, 1]</c>), a key that array as text (<c>"[2026,1]"</c>).
/// The Executive Summary's <c>YearMonthColumns</c> and <c>ValuesByYearMonth</c> are these.
/// </summary>
public sealed class ValueTupleJsonConverterFactory : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) =>
        typeToConvert.IsValueType && typeToConvert.IsGenericType
        && typeToConvert.FullName?.StartsWith("System.ValueTuple`", StringComparison.Ordinal) == true
        && typeToConvert.GetGenericArguments().Length <= 7;

    public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options) =>
        (JsonConverter)Activator.CreateInstance(typeof(Converter<>).MakeGenericType(typeToConvert))!;

    private sealed class Converter<T> : JsonConverter<T> where T : struct, System.Runtime.CompilerServices.ITuple
    {
        private static readonly Type[] ElementTypes = typeof(T).GetGenericArguments();

        public override T Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType != JsonTokenType.StartArray)
                throw new JsonException($"Expected a JSON array for {typeof(T)}.");
            var values = new object?[ElementTypes.Length];
            int i = 0;
            while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
            {
                if (i >= values.Length) throw new JsonException($"Too many elements for {typeof(T)}.");
                values[i] = JsonSerializer.Deserialize(ref reader, ElementTypes[i], options);
                i++;
            }
            if (i != values.Length) throw new JsonException($"Expected {values.Length} elements for {typeof(T)}, got {i}.");
            return (T)Activator.CreateInstance(typeof(T), values)!;
        }

        public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
        {
            writer.WriteStartArray();
            for (int i = 0; i < ElementTypes.Length; i++)
                JsonSerializer.Serialize(writer, value[i], ElementTypes[i], options);
            writer.WriteEndArray();
        }

        public override T ReadAsPropertyName(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            var text = reader.GetString() ?? throw new JsonException($"Empty key for {typeof(T)}.");
            var keyReader = new Utf8JsonReader(System.Text.Encoding.UTF8.GetBytes(text));
            keyReader.Read();
            return Read(ref keyReader, typeToConvert, options);
        }

        public override void WriteAsPropertyName(Utf8JsonWriter writer, T value, JsonSerializerOptions options)
        {
            using var buffer = new MemoryStream();
            using (var keyWriter = new Utf8JsonWriter(buffer))
                Write(keyWriter, value, options);
            writer.WritePropertyName(System.Text.Encoding.UTF8.GetString(buffer.ToArray()));
        }
    }
}
