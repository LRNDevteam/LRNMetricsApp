using System.Globalization;
using CsvHelper;
using CsvHelper.Configuration;
using CsvHelper.TypeConversion;

namespace LRN.AveragesImport.Core.Csv;

/// <summary>Blank -> null; otherwise M/d/yyyy (with a few tolerant fallbacks).</summary>
public sealed class BlankToNullDateConverter : DefaultTypeConverter
{
    private static readonly string[] Formats =
    {
        "M/d/yyyy", "M/d/yyyy H:mm", "M/d/yyyy H:mm:ss", "M/d/yyyy h:mm:ss tt", "yyyy-MM-dd"
    };

    public override object? ConvertFromString(string? text, IReaderRow row, MemberMapData memberMapData)
    {
        text = text?.Trim();
        if (string.IsNullOrEmpty(text))
            return null;

        if (DateTime.TryParseExact(text, Formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
            return dt;
        if (DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out dt))
            return dt;

        throw new TypeConverterException(this, memberMapData, text, row.Context, $"Invalid date value '{text}'.");
    }
}

/// <summary>Blank -> null; otherwise invariant decimal.</summary>
public sealed class BlankToNullDecimalConverter : DefaultTypeConverter
{
    public override object? ConvertFromString(string? text, IReaderRow row, MemberMapData memberMapData)
    {
        text = text?.Trim();
        if (string.IsNullOrEmpty(text))
            return null;

        if (decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out var value))
            return value;

        throw new TypeConverterException(this, memberMapData, text, row.Context, $"Invalid decimal value '{text}'.");
    }
}

/// <summary>
/// Blank -> null; otherwise parses as decimal and rounds to int, because integer
/// columns (notably AvgUnits) may arrive as decimal strings like "1.0".
/// </summary>
public sealed class BlankToNullIntConverter : DefaultTypeConverter
{
    public override object? ConvertFromString(string? text, IReaderRow row, MemberMapData memberMapData)
    {
        text = text?.Trim();
        if (string.IsNullOrEmpty(text))
            return null;

        if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var i))
            return i;
        if (decimal.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out var d))
            return (int)Math.Round(d, MidpointRounding.AwayFromZero);

        throw new TypeConverterException(this, memberMapData, text, row.Context, $"Invalid integer value '{text}'.");
    }
}
