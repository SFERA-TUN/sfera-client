using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Sfera.Windows;

internal sealed record Profile(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("host")] string Host,
    [property: JsonPropertyName("peerIP")] string PeerIP,
    [property: JsonPropertyName("token")] string Token)
{
    internal static readonly string DataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SFERA");
    private static string SavedPath => Path.Combine(DataDirectory, "profile.dat");

    internal string Gateway
    {
        get
        {
            var bytes = IPv4(PeerIP)!;
            return $"{bytes[0]}.{bytes[1]}.{bytes[2]}.{bytes[3] - 1}";
        }
    }

    internal static Profile Import(string path) => Decode(ReadLimited(path, 4096));

    internal static Profile? Load()
    {
        if (!File.Exists(SavedPath)) return null;
        var bytes = ProtectedData.Unprotect(ReadLimited(SavedPath, 8192), null, DataProtectionScope.CurrentUser);
        return Decode(bytes);
    }

    internal void Save()
    {
        Directory.CreateDirectory(DataDirectory);
        var bytes = ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(this), null, DataProtectionScope.CurrentUser);
        var temporary = Path.Combine(DataDirectory, $"{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, SavedPath, overwrite: true);
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private static byte[] ReadLimited(string path, int limit)
    {
        using var stream = File.OpenRead(path);
        var data = new byte[limit + 1];
        var size = stream.ReadAtLeast(data, data.Length, throwIfEndOfStream: false);
        if (size > limit) throw Invalid();
        return data[..size];
    }

    internal static Profile Decode(ReadOnlySpan<byte> data)
    {
        if (data.StartsWith(new byte[] { 0xef, 0xbb, 0xbf })) data = data[3..];
        Profile? profile;
        try { profile = JsonSerializer.Deserialize<Profile>(data); }
        catch (JsonException) { throw Invalid(); }

        if (profile is null || profile.Version != 1 ||
            string.IsNullOrWhiteSpace(profile.Name) || profile.Name.Length > 120 ||
            IPv4(profile.Host) is not [> 0 and < 224, _, _, _] ||
            IPv4(profile.PeerIP) is not [var a, var b, _, var last] || last % 4 != 2 ||
            !(a == 10 || (a == 172 && b is >= 16 and <= 31) || (a == 192 && b == 168)) ||
            profile.Token is not { Length: 64 } ||
            !profile.Token.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f'))
            throw Invalid();
        return profile;
    }

    private static byte[]? IPv4(string? value)
    {
        var parts = value?.Split('.');
        if (parts?.Length != 4) return null;
        var bytes = new byte[4];
        for (int i = 0; i < parts.Length; i++)
            if (!byte.TryParse(parts[i], out bytes[i]) || parts[i] != bytes[i].ToString())
                return null;
        return bytes;
    }

    private static InvalidDataException Invalid() => new("Выберите корректный JSON-профиль SFERA.");
}
