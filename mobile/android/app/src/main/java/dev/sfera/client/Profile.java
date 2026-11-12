package dev.sfera.client;

import android.content.Context;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import android.util.AtomicFile;
import org.json.JSONObject;

final class Profile {
    final String name;
    final String host;
    final String peer;
    final String token;

    private Profile(JSONObject json) throws Exception {
        name = json.getString("name");
        host = json.getString("host");
        peer = json.getString("peerIP");
        token = json.getString("token");
        int[] address = ipv4(peer);
        int[] server = ipv4(host);
        boolean privatePeer = address[0] == 10 || address[0] == 192 && address[1] == 168 ||
            address[0] == 172 && address[1] >= 16 && address[1] <= 31;
        if (json.getInt("version") != 1 || name.trim().isEmpty() || name.length() > 120 ||
            !privatePeer || address[3] % 4 != 2 || server[0] == 0 || server[0] >= 224 ||
            !token.matches("[0-9a-f]{64}")) {
            throw new IllegalArgumentException("Invalid SFERA profile");
        }
    }

    private static int[] ipv4(String value) {
        String[] fields = value.split("\\.", -1);
        if (fields.length != 4) throw new IllegalArgumentException("Expected IPv4");
        int[] result = new int[4];
        for (int i = 0; i < fields.length; i++) {
            if (!fields[i].matches("0|[1-9][0-9]{0,2}")) throw new IllegalArgumentException("Expected IPv4");
            result[i] = Integer.parseInt(fields[i]);
            if (result[i] > 255) throw new IllegalArgumentException("Expected IPv4");
        }
        return result;
    }

    private static AtomicFile store(Context context) {
        return new AtomicFile(new File(context.getNoBackupFilesDir(), "sfera-profile.json"));
    }

    static Profile load(Context context) throws Exception {
        try (FileInputStream source = store(context).openRead()) {
            return new Profile(new JSONObject(new String(read(source), StandardCharsets.UTF_8)));
        }
    }

    static void importFile(Context context, InputStream source) throws Exception {
        byte[] data = read(source);
        new Profile(new JSONObject(new String(data, StandardCharsets.UTF_8)));
        AtomicFile file = store(context);
        var output = file.startWrite();
        try {
            output.write(data);
            file.finishWrite(output);
        } catch (Exception error) {
            file.failWrite(output);
            throw error;
        }
    }

    private static byte[] read(InputStream input) throws Exception {
        if (input == null) throw new IllegalArgumentException("Cannot read file");
        var buffer = new byte[1024];
        var result = new ByteArrayOutputStream();
        int read;
        while ((read = input.read(buffer)) != -1) {
            if (result.size() + read > 4096) throw new IllegalArgumentException("Profile too large");
            result.write(buffer, 0, read);
        }
        return result.toByteArray();
    }
}
