using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LabMetricsDashboard.Models.Notes;

/// <summary>
/// Treats JSON null / "" / whitespace as null for DateTime? so Insights save
/// payloads with empty date inputs bind instead of failing the whole body.
/// </summary>
public sealed class NullableDateTimeJsonConverter : JsonConverter<DateTime?>
{
    public override DateTime? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null)
            return null;

        if (reader.TokenType == JsonTokenType.String)
        {
            var s = reader.GetString();
            if (string.IsNullOrWhiteSpace(s))
                return null;

            if (DateTime.TryParse(s, CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeLocal | DateTimeStyles.AllowWhiteSpaces, out var dt))
                return dt;

            if (DateTime.TryParse(s, CultureInfo.CurrentCulture,
                    DateTimeStyles.AssumeLocal | DateTimeStyles.AllowWhiteSpaces, out dt))
                return dt;

            throw new JsonException($"Invalid date value '{s}'.");
        }

        if (reader.TokenType == JsonTokenType.Number && reader.TryGetInt64(out var epoch))
            return DateTimeOffset.FromUnixTimeMilliseconds(epoch).LocalDateTime;

        throw new JsonException($"Unexpected token {reader.TokenType} for DateTime?.");
    }

    public override void Write(Utf8JsonWriter writer, DateTime? value, JsonSerializerOptions options)
    {
        if (value is null)
            writer.WriteNullValue();
        else
            writer.WriteStringValue(value.Value.ToString("o", CultureInfo.InvariantCulture));
    }
}
