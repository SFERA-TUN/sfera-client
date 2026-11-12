package dev.sfera.client;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.VpnService;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

public final class MainActivity extends Activity {
    private static final int IMPORT_PROFILE = 1;
    private static final int VPN_PERMISSION = 2;
    private static final int BACKGROUND = Color.rgb(19, 20, 23);
    private static final int PANEL = Color.rgb(26, 28, 32);
    private static final int AMBER = Color.rgb(245, 191, 122);
    private static final int MUTED = Color.rgb(180, 181, 188);
    private final Handler main = new Handler(Looper.getMainLooper());
    private TextView profileName;
    private TextView profileHost;
    private TextView status;
    private TextView message;
    private Button connection;
    private Button importButton;
    private Button directSites;
    private Profile profile;

    @Override public void onCreate(Bundle savedState) {
        super.onCreate(savedState);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(BACKGROUND);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            var system = insets.getSystemWindowInsets();
            view.setPadding(system.left, system.top, system.right, system.bottom);
            return insets;
        });
        LinearLayout layout = column(22);
        scroll.addView(layout, new ScrollView.LayoutParams(-1, -2));
        TextView brand = text("SFERA", 17, AMBER, true);
        brand.setLetterSpacing(0.12f);
        add(layout, brand, 0);
        add(layout, text("Подключение", 29, Color.WHITE, true), 24);
        LinearLayout card = column(18);
        card.setBackground(surface(PANEL));
        add(layout, card, 20);
        profileName = text("", 21, Color.WHITE, true);
        profileHost = text("", 14, MUTED, false);
        status = text("", 15, AMBER, true);
        status.setAccessibilityLiveRegion(TextView.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(card, profileName, 0);
        add(card, profileHost, 7);
        add(card, status, 18);
        connection = button("Подключить VPN", true);
        connection.setOnClickListener(view -> toggle());
        add(card, connection, 16);
        importButton = button("Импортировать профиль", false);
        importButton.setOnClickListener(view -> startActivityForResult(
            new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*"), IMPORT_PROFILE));
        add(layout, importButton, 14);
        if (Build.VERSION.SDK_INT >= 33) {
            directSites = button("Сайты без VPN", false);
            directSites.setOnClickListener(view -> editDirectSites());
            add(layout, directSites, 8);
        }
        message = text("", 14, AMBER, false);
        message.setAccessibilityLiveRegion(TextView.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(layout, message, 12);
        setContentView(scroll);
    }

    @Override public void onResume() {
        super.onResume();
        loadProfile();
        main.post(this::poll);
    }

    @Override public void onPause() {
        main.removeCallbacksAndMessages(null);
        super.onPause();
    }

    private void poll() {
        update();
        main.postDelayed(this::poll, 350);
    }

    private void loadProfile() {
        try { profile = Profile.load(this); } catch (Exception error) { profile = null; }
        profileName.setText(profile == null ? "Добавьте VPN-профиль" : profile.name);
        profileHost.setText(profile == null ? "Откройте файл SFERA, выданный владельцем сервера." : profile.host);
        update();
    }

    private void update() {
        if (!SferaVpn.state.contentEquals(status.getText())) status.setText(SferaVpn.state);
        String action = SferaVpn.active ? "Отключить VPN" : "Подключить VPN";
        if (!action.contentEquals(connection.getText())) connection.setText(action);
        connection.setEnabled((profile != null || SferaVpn.active) && !SferaVpn.state.equals("Отключаемся…"));
        importButton.setEnabled(!SferaVpn.active);
        if (directSites != null) directSites.setEnabled(!SferaVpn.active);
    }

    private void editDirectSites() {
        DirectSites saved = DirectSites.load(this);
        var fields = column(20);
        var enabled = new CheckBox(this);
        enabled.setText("Раздельное туннелирование");
        enabled.setChecked(saved.enabled);
        add(fields, enabled, 0);
        add(fields, text("Настройки применятся при следующем подключении. Список сохранится при выключении.",
            13, MUTED, false), 4);
        var preset = new CheckBox(this);
        preset.setText("Популярные сайты России");
        preset.setChecked(saved.useRussianSites);
        add(fields, preset, 12);
        var input = new EditText(this);
        input.setHint("Домены или ссылки, по одному на строку");
        input.setContentDescription("Свои сайты без VPN");
        input.setInputType(android.text.InputType.TYPE_CLASS_TEXT |
            android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE |
            android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        input.setMinLines(3);
        input.setMaxLines(6);
        input.setText(saved.custom);
        add(fields, input, 12);
        add(fields, text("Исключения действуют на IPv4-адреса, найденные при подключении. " +
            "Сайты с общим IP тоже могут пойти напрямую. Поддомены добавляются отдельно.",
            13, MUTED, false), 12);
        var scroll = new ScrollView(this);
        scroll.addView(fields);
        var dialog = new AlertDialog.Builder(this).setTitle("Сайты без VPN").setView(scroll)
            .setNegativeButton("Отмена", null).setPositiveButton("Сохранить", null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE)
            .setOnClickListener(view -> {
                try {
                    new DirectSites(enabled.isChecked(), preset.isChecked(), input.getText().toString())
                        .save(this);
                    dialog.dismiss();
                } catch (IllegalArgumentException error) {
                    input.setError(error.getLocalizedMessage());
                }
            }));
        dialog.show();
    }

    private void toggle() {
        message.setText("");
        if (SferaVpn.active) {
            startService(new Intent(this, SferaVpn.class).setAction(SferaVpn.STOP));
            return;
        }
        Intent permission = VpnService.prepare(this);
        if (permission == null) startVpn();
        else startActivityForResult(permission, VPN_PERMISSION);
    }

    private void startVpn() {
        startForegroundService(new Intent(this, SferaVpn.class).setAction(SferaVpn.START));
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (result != RESULT_OK) return;
        if (request == VPN_PERMISSION) startVpn();
        if (request == IMPORT_PROFILE && data != null && data.getData() != null) {
            try (var input = getContentResolver().openInputStream(data.getData())) {
                Profile.importFile(this, input);
                message.setText("Профиль сохранён.");
                loadProfile();
            } catch (Exception error) {
                message.setText("Не удалось открыть профиль SFERA. Проверьте JSON-файл.");
            }
        }
    }

    private LinearLayout column(int padding) {
        var view = new LinearLayout(this);
        view.setOrientation(LinearLayout.VERTICAL);
        int inset = dp(padding);
        view.setPadding(inset, inset, inset, inset);
        return view;
    }

    private TextView text(String title, int size, int color, boolean bold) {
        var view = new TextView(this);
        view.setText(title);
        view.setTextSize(size);
        view.setTextColor(color);
        if (bold) view.setTypeface(Typeface.DEFAULT_BOLD);
        return view;
    }

    private Button button(String title, boolean primary) {
        var view = new Button(this);
        view.setText(title);
        view.setAllCaps(false);
        view.setTextColor(ColorStateList.valueOf(primary ? BACKGROUND : Color.WHITE));
        view.setBackgroundTintList(new ColorStateList(
            new int[][] {new int[] {-android.R.attr.state_enabled}, new int[0]},
            new int[] {primary ? MUTED : PANEL, primary ? AMBER : PANEL}));
        view.setMinHeight(dp(48));
        return view;
    }

    private GradientDrawable surface(int color) {
        var result = new GradientDrawable();
        result.setColor(color);
        result.setCornerRadius(dp(16));
        return result;
    }

    private void add(LinearLayout parent, android.view.View child, int margin) {
        var params = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        params.topMargin = dp(margin);
        parent.addView(child, params);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
