package dev.sfera.client;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Intent;
import android.net.IpPrefix;
import android.net.VpnService;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import java.io.IOException;
import java.net.InetAddress;
import java.util.Collections;
import java.util.List;

public final class SferaVpn extends VpnService {
    static final String START = "dev.sfera.client.START";
    static final String STOP = "dev.sfera.client.STOP";
    static volatile String state = "Отключено";
    static volatile boolean active;
    private static final int NOTIFICATION = 1;
    private final Handler main = new Handler(Looper.getMainLooper());
    private ParcelFileDescriptor tunnel;
    private long handle;
    private boolean stopping;
    private int attempt;

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || !START.equals(intent.getAction())) {
            stopTunnel();
            return START_NOT_STICKY;
        }
        if (active) return START_NOT_STICKY;
        stopping = false;
        publish("Подключаемся…", true);
        int generation = ++attempt;
        DirectSites sites = DirectSites.load(this);
        if (Build.VERSION.SDK_INT >= 33 && sites.configured()) {
            new Thread(() -> {
                try {
                    List<String> addresses = sites.resolve();
                    main.post(() -> {
                        if (generation == attempt) establish(addresses);
                    });
                } catch (Exception error) {
                    main.post(() -> {
                        if (generation == attempt) {
                            finished(-1);
                            state = error.getLocalizedMessage();
                        }
                    });
                }
            }, "SFERA DNS").start();
        } else {
            establish(Collections.emptyList());
        }
        return START_NOT_STICKY;
    }

    private void establish(List<String> directIPv4) {
        try {
            Profile profile = Profile.load(this);
            // The transport and HTTPS signaling use the underlying network.
            Builder builder = new Builder().setSession("SFERA")
                .setMtu(1280).addAddress(profile.peer, 30).addRoute("0.0.0.0", 0)
                .addDnsServer("1.1.1.1").addDnsServer("9.9.9.9")
                .addDisallowedApplication(getPackageName());
            if (Build.VERSION.SDK_INT >= 33) {
                for (String ip : directIPv4) {
                    builder.excludeRoute(new IpPrefix(InetAddress.getByName(ip), 32));
                }
            }
            tunnel = builder.establish();
            if (tunnel == null) throw new IOException("VPN permission unavailable");
            handle = NativeTunnel.create();
            long session = handle;
            int fd = tunnel.getFd();
            new Thread(() -> {
                int result = -1;
                try {
                    result = NativeTunnel.run(session, fd, profile.host, profile.peer, profile.token);
                } finally {
                    int finalResult = result;
                    main.post(() -> finished(finalResult));
                }
            }, "SFERA transport").start();
            main.postDelayed(this::poll, 250);
        } catch (Exception | LinkageError error) {
            finished(-1);
        }
    }

    private void poll() {
        if (handle == 0 || stopping) return;
        int status = NativeTunnel.status(handle);
        String next = status == 1 ? "Подключено" : "Подключаемся…";
        if (!next.equals(state)) publish(next, true);
        main.postDelayed(this::poll, 350);
    }

    private void stopTunnel() {
        if (stopping) return;
        ++attempt;
        if (handle == 0) {
            if (active) finished(2);
            else stopSelf();
            return;
        }
        stopping = true;
        publish("Отключаемся…", true);
        NativeTunnel.stop(handle);
    }

    private void finished(int result) {
        if (handle != 0) {
            NativeTunnel.free(handle);
            handle = 0;
        }
        if (tunnel != null) {
            try { tunnel.close(); } catch (IOException ignored) {}
            tunnel = null;
        }
        state = result == -1 && !stopping ? "Ошибка подключения. Проверьте сервер и профиль." : "Отключено";
        active = false;
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void publish(String message, boolean running) {
        state = message;
        active = running;
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel("vpn", "SFERA VPN", NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent stop = PendingIntent.getService(this, 1, new Intent(this, SferaVpn.class).setAction(STOP),
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        var notification = new Notification.Builder(this, "vpn").setContentTitle("SFERA VPN")
            .setContentText(message).setSmallIcon(R.drawable.sfera_icon).setContentIntent(open)
            .setOngoing(true).addAction(new Notification.Action.Builder(null, "Отключить", stop).build())
            .build();
        startForeground(NOTIFICATION, notification);
    }

    @Override public void onRevoke() {
        main.post(this::stopTunnel);
    }

    @Override public void onDestroy() {
        if (active) stopTunnel();
        super.onDestroy();
    }
}
