using System.Security.Cryptography;
using System.Text.Json;

namespace Sfera.Windows;

internal sealed class ConnectionWindow : Form
{
    private readonly Label profileName = Style.Label("Добавьте профиль", 20, bold: true);
    private readonly Label profileHost = Style.Label("Откройте JSON-файл, выданный для этого устройства.", 10, muted: true);
    private readonly Label status = Style.Label("VPN отключён", 11, bold: true, muted: true);
    private readonly Label notice = Style.Label("", 10, muted: true);
    private readonly Button connect = Style.Button("Подключить VPN", primary: true);
    private readonly Button import = Style.Button("Импортировать профиль");
    private readonly Button exceptions = Style.Button("Сайты без VPN");
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 250 };
    private Profile? profile;
    private DirectSites sites = new();
    private TunnelSession? session;
    private CancellationTokenSource? resolving;
    private bool stopping;
    private bool closeRequested;

    internal ConnectionWindow()
    {
        Text = "SFERA";
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Style.Background;
        ForeColor = Style.Text;
        Font = new Font("Segoe UI Variable Text", 10);
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(540, 470);
        MinimumSize = new Size(490, 475);

        var layout = Style.Column(26);
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 202));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 61));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var brand = Style.Label("SFERA", 12, bold: true);
        brand.ForeColor = Style.Amber;
        layout.Controls.Add(brand, 0, 0);
        layout.Controls.Add(Style.Label("Подключение", 27, bold: true), 0, 1);

        var card = Style.Column(17);
        card.BackColor = Style.Surface;
        foreach (var height in new[] { 42, 34, 38, 47 })
            card.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        card.Controls.Add(profileName, 0, 0);
        card.Controls.Add(profileHost, 0, 1);
        card.Controls.Add(status, 0, 2);
        card.Controls.Add(connect, 0, 3);
        layout.Controls.Add(card, 0, 2);

        var actions = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Margin = new Padding(0, 11, 0, 0),
            ColumnCount = 2
        };
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 56));
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 44));
        import.Margin = new Padding(0, 0, 8, 7);
        exceptions.Margin = new Padding(0, 0, 0, 7);
        actions.Controls.Add(import, 0, 0);
        actions.Controls.Add(exceptions, 1, 0);
        layout.Controls.Add(actions, 0, 3);
        notice.TextAlign = ContentAlignment.TopLeft;
        layout.Controls.Add(notice, 0, 4);
        Controls.Add(layout);

        connect.Click += async (_, _) => await ToggleAsync();
        import.Click += (_, _) => ImportProfile();
        exceptions.Click += (_, _) => EditSites();
        timer.Tick += (_, _) => Poll();
        FormClosing += CloseConnection;
        FormClosed += (_, _) => timer.Dispose();

        try { profile = Profile.Load(); }
        catch (Exception error) when (error is IOException or InvalidDataException or CryptographicException or UnauthorizedAccessException)
        {
            notice.Text = "Не удалось прочитать сохранённый профиль. Импортируйте его снова.";
        }
        try { sites = DirectSites.Load(); }
        catch (Exception error) when (error is IOException or InvalidDataException or JsonException or UnauthorizedAccessException)
        {
            notice.Text = "Не удалось прочитать настройки сайтов без VPN. Сохраните их заново.";
        }
        ShowProfile();
        timer.Start();
    }

    private void ShowProfile()
    {
        profileName.Text = profile?.Name ?? "Добавьте профиль";
        profileHost.Text = profile?.Host ?? "Откройте JSON-файл, выданный для этого устройства.";
        RefreshActions();
    }

    private void ImportProfile()
    {
        using var dialog = new OpenFileDialog { Filter = "Профиль SFERA (*.json)|*.json", Multiselect = false };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            var imported = Profile.Import(dialog.FileName);
            imported.Save();
            profile = imported;
            notice.Text = "Профиль сохранён.";
            ShowProfile();
        }
        catch (Exception error) when (error is IOException or InvalidDataException or CryptographicException or UnauthorizedAccessException)
        {
            notice.Text = error is InvalidDataException ? error.Message : "Не удалось открыть или сохранить профиль.";
        }
    }

    private void EditSites()
    {
        using var dialog = new SitesWindow(sites);
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            sites = dialog.Settings;
            notice.Text = "Настройки применятся при следующем подключении.";
        }
    }

    private async Task ToggleAsync()
    {
        if (resolving is not null || session is not null)
        {
            RequestStop();
            return;
        }
        var selected = profile;
        if (selected is null) return;

        var attempt = new CancellationTokenSource();
        resolving = attempt;
        notice.Text = "";
        status.Text = "Подключаемся…";
        RefreshActions();
        try
        {
            var addresses = await sites.ResolveAsync(attempt.Token);
            attempt.Token.ThrowIfCancellationRequested();
            session = TunnelSession.Start(selected, addresses);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or
            System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            notice.Text = error is InvalidDataException or FileNotFoundException ? error.Message : "Не удалось запустить VPN.";
        }
        finally
        {
            resolving = null;
            attempt.Dispose();
            if (session is null) Finish();
            RefreshActions();
        }
    }

    private void Poll()
    {
        if (session is null) return;
        var phase = session.Phase;
        if (!session.HasExited)
        {
            if (stopping) return;
            var connected = phase == "connected" && session.TransportState != "connecting";
            status.Text = connected ? "VPN подключён" : phase == "connected" ? "Восстанавливаем соединение…" : "Подключаемся…";
            status.ForeColor = connected ? Style.Connected : Style.Muted;
            return;
        }
        if (!stopping)
            notice.Text = phase switch
            {
                "already-running" => "SFERA уже запущена в другом окне.",
                "route-conflict" => "Обнаружен конфликт маршрутов. Отключите другой VPN и повторите.",
                "routes-error" => "Не удалось настроить маршруты Windows. Проверьте сеть и повторите подключение.",
                _ => "Не удалось подключиться. Проверьте профиль и доступность сервера."
            };
        session.Dispose();
        session = null;
        Finish();
    }

    private void RequestStop()
    {
        stopping = true;
        resolving?.Cancel();
        try { session?.Stop(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            stopping = false;
            notice.Text = "Не удалось остановить VPN. Закройте приложение для отключения.";
        }
        if (stopping) status.Text = "Отключаемся…";
        RefreshActions();
    }

    private void Finish()
    {
        stopping = false;
        status.Text = "VPN отключён";
        status.ForeColor = Style.Muted;
        RefreshActions();
        if (closeRequested) Close();
    }

    private void CloseConnection(object? sender, FormClosingEventArgs args)
    {
        if (session is null && resolving is null) return;
        closeRequested = true;
        RequestStop();
        args.Cancel = stopping;
    }

    private void RefreshActions()
    {
        var active = resolving is not null || session is not null;
        import.Enabled = exceptions.Enabled = !active;
        connect.Enabled = profile is not null && !stopping;
        connect.Text = active ? "Отключить VPN" : "Подключить VPN";
    }
}

internal sealed class SitesWindow : Form
{
    internal DirectSites Settings { get; private set; }

    internal SitesWindow(DirectSites settings)
    {
        Settings = settings;
        Text = "Сайты без VPN";
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(490, 430);
        MinimumSize = new Size(440, 425);
        BackColor = Style.Background;
        ForeColor = Style.Text;
        Font = new Font("Segoe UI Variable Text", 10);

        var layout = Style.Column(20);
        foreach (var height in new[] { 38, 34, 34, 28 })
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 62));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 45));

        var enabled = new CheckBox { Text = "Раздельное туннелирование", Checked = settings.Enabled, Dock = DockStyle.Fill };
        var russian = new CheckBox { Text = "Популярные сайты России", Checked = settings.Russian, Dock = DockStyle.Fill };
        var custom = new TextBox
        {
            Multiline = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Text = settings.Custom,
            BackColor = Style.Surface, ForeColor = Style.Text, AccessibleName = "Свои сайты"
        };
        var hint = Style.Label("IPv4-адреса определяются при подключении. Сайты на одном IP используют один маршрут.", 10, muted: true);
        var save = Style.Button("Сохранить", primary: true);
        save.Click += (_, _) =>
        {
            try
            {
                Settings = new DirectSites(enabled.Checked, russian.Checked, custom.Text);
                Settings.Save();
                DialogResult = DialogResult.OK;
            }
            catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException)
            {
                hint.Text = error is InvalidDataException ? error.Message : "Не удалось сохранить настройки.";
            }
        };
        layout.Controls.Add(Style.Label("Сайты без VPN", 20, bold: true), 0, 0);
        layout.Controls.Add(enabled, 0, 1);
        layout.Controls.Add(russian, 0, 2);
        layout.Controls.Add(Style.Label("Домены или ссылки, по одному на строку", 10, muted: true), 0, 3);
        layout.Controls.Add(custom, 0, 4);
        layout.Controls.Add(hint, 0, 5);
        layout.Controls.Add(save, 0, 6);
        Controls.Add(layout);
    }
}

internal static class Style
{
    internal static readonly Color Background = ColorTranslator.FromHtml("#131417");
    internal static readonly Color Surface = ColorTranslator.FromHtml("#1A1C20");
    internal static readonly Color Panel = ColorTranslator.FromHtml("#23252B");
    internal static readonly Color Text = ColorTranslator.FromHtml("#E4E4E7");
    internal static readonly Color Muted = ColorTranslator.FromHtml("#A1A1AA");
    internal static readonly Color Amber = ColorTranslator.FromHtml("#F5BF7A");
    internal static readonly Color Connected = ColorTranslator.FromHtml("#9ACDAD");

    internal static TableLayoutPanel Column(int padding) => new()
    {
        Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(padding), Margin = Padding.Empty
    };

    internal static Label Label(string text, int size, bool bold = false, bool muted = false) => new()
    {
        Text = text, Dock = DockStyle.Fill, Margin = Padding.Empty, AutoEllipsis = true,
        TextAlign = ContentAlignment.MiddleLeft, ForeColor = muted ? Muted : Text,
        Font = new Font("Segoe UI Variable Text", size, bold ? FontStyle.Bold : FontStyle.Regular)
    };

    internal static Button Button(string text, bool primary = false)
    {
        var button = new Button
        {
            Text = text, Dock = DockStyle.Fill, Margin = Padding.Empty, FlatStyle = FlatStyle.Flat,
            BackColor = primary ? Amber : Panel, ForeColor = primary ? Background : Text,
            UseVisualStyleBackColor = false
        };
        button.FlatAppearance.BorderColor = primary ? Amber : ColorTranslator.FromHtml("#36383E");
        return button;
    }
}
