package dev.sfera.client;

import android.content.Context;
import java.io.IOException;
import java.net.IDN;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.URI;
import java.net.UnknownHostException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.TreeSet;
import java.util.concurrent.Callable;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

final class DirectSites {
    // Keep in sync with DirectSites.swift.
    private static final String RUSSIAN_SITES =
        "yandex.ru ya.ru yastatic.net dzen.ru vk.com vk.ru vkvideo.ru userapi.com vkuser.net " +
        "mail.ru imgsmail.ru ok.ru gosuslugi.ru nalog.gov.ru mos.ru sberbank.ru sber.ru " +
        "tbank.ru tinkoff.ru alfabank.ru vtb.ru ozon.ru ozonusercontent.com wildberries.ru " +
        "wbstatic.net avito.ru avito.st auto.ru 2gis.ru rutube.ru rbc.ru hh.ru";

    final boolean useRussianSites;
    final String custom;

    DirectSites(boolean useRussianSites, String custom) {
        this.useRussianSites = useRussianSites;
        this.custom = custom;
    }

    static DirectSites load(Context context) {
        var preferences = context.getSharedPreferences("directSites", Context.MODE_PRIVATE);
        return new DirectSites(preferences.getBoolean("russian", false), preferences.getString("custom", ""));
    }

    void save(Context context) {
        hosts();
        context.getSharedPreferences("directSites", Context.MODE_PRIVATE).edit()
            .putBoolean("russian", useRussianSites).putString("custom", custom).apply();
    }

    boolean configured() {
        return useRussianSites || !custom.trim().isEmpty();
    }

    private List<String> hosts() {
        String limit = "В списке может быть не более 64 сайтов, включая готовый набор.";
        if (custom.getBytes(StandardCharsets.UTF_8).length > 8192) throw new IllegalArgumentException(limit);
        var hosts = new TreeSet<String>();
        String input = useRussianSites ? RUSSIAN_SITES + " " + custom : custom;
        for (String item : input.split("[\\s,;]+")) {
            if (item.isEmpty()) continue;
            try {
                URI url = URI.create(item.contains("://") ? item : "https://" + item);
                String authority = url.getAuthority();
                String scheme = url.getScheme();
                if (authority == null || authority.contains("@") ||
                    !("https".equalsIgnoreCase(scheme) || "http".equalsIgnoreCase(scheme))) {
                    throw new IllegalArgumentException();
                }
                String name = authority.replaceFirst(":[0-9]+$", "").replaceFirst("\\.$", "");
                String host = IDN.toASCII(name, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
                if (host.length() > 253 || !host.contains(".") || host.startsWith(".") || host.endsWith(".")) {
                    throw new IllegalArgumentException();
                }
                hosts.add(host);
            } catch (IllegalArgumentException error) {
                throw new IllegalArgumentException("Некорректный сайт: " + item.substring(0, Math.min(item.length(), 120)));
            }
        }
        if (hosts.size() > 64) throw new IllegalArgumentException(limit);
        return new ArrayList<>(hosts);
    }

    List<String> resolve() throws Exception {
        var hosts = hosts();
        if (hosts.isEmpty()) return Collections.emptyList();
        var pool = Executors.newFixedThreadPool(Math.min(8, hosts.size()));
        try {
            var lookups = new ArrayList<Callable<List<String>>>();
            for (String host : hosts) lookups.add(() -> ipv4(host));
            var addresses = new TreeSet<String>();
            for (var lookup : pool.invokeAll(lookups, 12, TimeUnit.SECONDS)) {
                if (!lookup.isCancelled()) addresses.addAll(lookup.get());
            }
            if (addresses.isEmpty()) throw new IOException("Не удалось найти IPv4-адреса сайтов. Проверьте список и сеть.");
            if (addresses.size() > 96) throw new IOException("Найдено больше 96 IPv4-адресов. Сократите список сайтов.");
            return new ArrayList<>(addresses);
        } finally {
            pool.shutdownNow();
        }
    }

    private static List<String> ipv4(String host) {
        var addresses = new ArrayList<String>();
        try {
            for (InetAddress address : InetAddress.getAllByName(host + ".")) {
                if (!(address instanceof Inet4Address)) continue;
                byte[] bytes = address.getAddress();
                int a = bytes[0] & 255, b = bytes[1] & 255, c = bytes[2] & 255;
                String ip = address.getHostAddress();
                if (a == 0 || a >= 224 || a == 10 || a == 127 || (a == 100 && b >= 64 && b <= 127) ||
                    (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31) ||
                    (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)))) ||
                    (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
                    (a == 203 && b == 0 && c == 113) || "1.1.1.1".equals(ip) || "9.9.9.9".equals(ip)) continue;
                addresses.add(ip);
            }
        } catch (UnknownHostException ignored) {}
        return addresses;
    }
}
