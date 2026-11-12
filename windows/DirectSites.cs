using System.Net;
using System.Net.Sockets;
using System.Text.Json;

namespace Sfera.Windows;

internal sealed record DirectSites(bool Enabled = false, bool Russian = false, string Custom = "")
{
    private const string RussianSites =
        "yandex.ru ya.ru yastatic.net dzen.ru vk.com vk.ru vkvideo.ru userapi.com vkuser.net " +
        "mail.ru imgsmail.ru ok.ru gosuslugi.ru nalog.gov.ru mos.ru sberbank.ru sber.ru " +
        "tbank.ru tinkoff.ru alfabank.ru vtb.ru ozon.ru cdn1.ozone.ru wildberries.ru " +
        "wbstatic.net avito.ru avito.st auto.ru 2gis.ru rutube.ru rbc.ru hh.ru";
    private static string SettingsPath => Path.Combine(Profile.DataDirectory, "direct-sites.json");

    internal static DirectSites Load()
    {
        if (!File.Exists(SettingsPath)) return new();
        var sites = JsonSerializer.Deserialize<DirectSites>(File.ReadAllText(SettingsPath)) ?? new();
        _ = sites.Hosts();
        return sites;
    }

    internal void Save()
    {
        _ = Hosts();
        Directory.CreateDirectory(Profile.DataDirectory);
        var temporary = Path.Combine(Profile.DataDirectory, $"{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(this));
            File.Move(temporary, SettingsPath, overwrite: true);
        }
        finally { File.Delete(temporary); }
    }

    internal string[] Hosts()
    {
        if (Custom is null || Custom.Length > 8192) throw new InvalidDataException("Список сайтов слишком длинный.");
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (Russian) result.UnionWith(RussianSites.Split(' '));
        foreach (var item in Custom.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var address = item.Contains("://", StringComparison.Ordinal) ? item : "https://" + item;
            if (!Uri.TryCreate(address, UriKind.Absolute, out var url) ||
                url.Scheme is not ("http" or "https") || url.UserInfo.Length != 0 ||
                url.HostNameType is not (UriHostNameType.Dns or UriHostNameType.IPv4) ||
                !url.IdnHost.Contains('.', StringComparison.Ordinal))
                throw new InvalidDataException($"Некорректный сайт: {item[..Math.Min(item.Length, 120)]}");
            result.Add(url.IdnHost.TrimEnd('.'));
        }
        if (result.Count > 64) throw new InvalidDataException("Добавьте не более 64 сайтов, включая готовый список.");
        return result.Order(StringComparer.Ordinal).ToArray();
    }

    internal async Task<string[]> ResolveAsync(CancellationToken token)
    {
        if (!Enabled) return [];
        var hosts = Hosts();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(12));
        using var limit = new SemaphoreSlim(8);
        var results = await Task.WhenAll(hosts.Select(async host =>
        {
            try
            {
                await limit.WaitAsync(deadline.Token).ConfigureAwait(false);
                try
                {
                    var addresses = await Dns.GetHostAddressesAsync(host, AddressFamily.InterNetwork, deadline.Token)
                        .ConfigureAwait(false);
                    return (Host: host, Addresses: addresses.Where(IsPublic).Select(ip => ip.ToString()).ToArray());
                }
                finally { limit.Release(); }
            }
            catch (Exception error) when (error is SocketException or OperationCanceledException)
            {
                return (Host: host, Addresses: Array.Empty<string>());
            }
        })).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();

        var unresolved = results.Where(result => result.Addresses.Length == 0).Select(result => result.Host).ToArray();
        if (unresolved.Length != 0)
        {
            var names = string.Join(", ", unresolved.Take(5));
            var suffix = unresolved.Length > 5 ? $" и ещё {unresolved.Length - 5}" : "";
            throw new InvalidDataException($"Нет IPv4 для: {names}{suffix}. Исправьте список или отключите исключения.");
        }
        var addresses = results.SelectMany(result => result.Addresses).Distinct().ToArray();
        if (addresses.Length > 96) throw new InvalidDataException("Найдено больше 96 IPv4-адресов. Сократите список сайтов.");
        return addresses;
    }

    private static bool IsPublic(IPAddress address)
    {
        if (address.GetAddressBytes() is not [var a, var b, var c, _]) return false;
        return a is > 0 and < 224 and not (10 or 127) &&
            !(a == 100 && b is >= 64 and <= 127) &&
            !(a == 169 && b == 254) &&
            !(a == 172 && b is >= 16 and <= 31) &&
            !(a == 192 && (b == 168 || (b == 0 && c is 0 or 2))) &&
            !(a == 198 && (b is 18 or 19 || (b == 51 && c == 100))) &&
            !(a == 203 && b == 0 && c == 113) &&
            address.ToString() is not ("1.1.1.1" or "9.9.9.9");
    }
}
