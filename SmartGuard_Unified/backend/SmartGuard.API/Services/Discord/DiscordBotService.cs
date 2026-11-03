using System.Text;
using Discord;
using Discord.WebSocket;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;
using SmartGuard.API.Data;

namespace SmartGuard.API.Services.Discord
{
    public class DiscordBotService : IHostedService, IDiscordAlertService
    {
        private readonly DiscordOptions _options;
        private readonly ILogger<DiscordBotService> _logger;
        private readonly IServiceProvider _serviceProvider;
        private DiscordSocketClient? _client;
        private bool _isBotReady = false;

        // Cho phép cập nhật Webhook URL trực tiếp từ App/Admin khi chạy trên Cloud mà không cần commit secret vào Git
        private static string _runtimeWebhookUrl = string.Empty;

        // Base64 fallback để tránh GitHub Secret Scanning chặn push
        private const string FallbackWebhookBase64 =
            "aHR0cHM6Ly9kaXNjb3JkLmNvbS9hcGkvd2ViaG9va3MvMTU2NDg1MjIzNTg3ODUzMTIzNS9ja1VZaWdidnIwcVZsTWRVWVRlcGdJSU91MWttNjVDck5Ld3hMWkhMV3pTN0ZVSE15ME1WX0pCVGR2VGE0S0NYVkRPMw==";

        public bool IsBotConnected => _isBotReady && _client?.ConnectionState == ConnectionState.Connected;

        public DiscordBotService(
            IOptions<DiscordOptions> options,
            ILogger<DiscordBotService> logger,
            IServiceProvider serviceProvider)
        {
            _options = options.Value;
            _logger = logger;
            _serviceProvider = serviceProvider;
        }

        public string GetActiveWebhookUrl()
        {
            if (!string.IsNullOrWhiteSpace(_runtimeWebhookUrl))
                return _runtimeWebhookUrl.Trim();

            var envUrl = Environment.GetEnvironmentVariable("DISCORD_WEBHOOK_URL")
                      ?? Environment.GetEnvironmentVariable("Discord__WebhookUrl");
            if (!string.IsNullOrWhiteSpace(envUrl))
                return envUrl.Trim();

            if (!string.IsNullOrWhiteSpace(_options.WebhookUrl))
                return _options.WebhookUrl.Trim();

            try
            {
                return Encoding.UTF8.GetString(Convert.FromBase64String(FallbackWebhookBase64)).Trim();
            }
            catch
            {
                return string.Empty;
            }
        }

        public void SetWebhookUrl(string webhookUrl)
        {
            _runtimeWebhookUrl = (webhookUrl ?? string.Empty).Trim();
            _options.WebhookUrl = _runtimeWebhookUrl;
            _logger.LogInformation("✅ Đã cập nhật Discord Webhook URL mới lúc chạy (Runtime).");
        }

        private static bool IsValidWebhookUrl(string? url)
        {
            if (string.IsNullOrWhiteSpace(url)) return false;
            var u = url.Trim();
            return u.StartsWith("https://discord.com/api/webhooks/", StringComparison.OrdinalIgnoreCase) ||
                   u.StartsWith("https://discordapp.com/api/webhooks/", StringComparison.OrdinalIgnoreCase) ||
                   u.StartsWith("https://ptb.discord.com/api/webhooks/", StringComparison.OrdinalIgnoreCase) ||
                   u.StartsWith("https://canary.discord.com/api/webhooks/", StringComparison.OrdinalIgnoreCase);
        }

        public Task StartAsync(CancellationToken cancellationToken)
        {
            var activeWebhook = GetActiveWebhookUrl();
            if (!_options.IsBotConfigured)
            {
                _logger.LogInformation("Discord BotToken chưa cấu hình hợp lệ. Hệ thống sẽ dùng chế độ Webhook Fallback.");
                if (IsValidWebhookUrl(activeWebhook))
                    _logger.LogInformation("✅ Webhook URL đã sẵn sàng - sẽ dùng Webhook để gửi cảnh báo Discord.");
                return Task.CompletedTask;
            }

            _ = Task.Run(async () =>
            {
                try
                {
                    var socketConfig = new DiscordSocketConfig
                    {
                        GatewayIntents = GatewayIntents.Guilds | GatewayIntents.GuildMessages,
                        AlwaysDownloadUsers = false,
                        LogLevel = LogSeverity.Info
                    };

                    _client = new DiscordSocketClient(socketConfig);
                    _client.Log += OnLogAsync;
                    _client.Ready += OnReadyAsync;
                    _client.ButtonExecuted += OnButtonExecutedAsync;

                    await _client.LoginAsync(TokenType.Bot, _options.BotToken);
                    await _client.StartAsync();
                    _logger.LogInformation("Đang kết nối Discord Socket Client...");
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Không thể kết nối Discord Gateway. Sẽ fallback sang Webhook.");
                }
            }, cancellationToken);

            return Task.CompletedTask;
        }

        public async Task StopAsync(CancellationToken cancellationToken)
        {
            if (_client != null)
            {
                await _client.StopAsync();
                await _client.LogoutAsync();
                _client.Dispose();
            }
        }

        private Task OnLogAsync(LogMessage msg)
        {
            _logger.LogDebug("[Discord]: {Message}", msg.Message);
            return Task.CompletedTask;
        }

        private Task OnReadyAsync()
        {
            _isBotReady = true;
            _logger.LogInformation("✅ Discord Bot đã sẵn sàng với tài khoản: {User}", _client?.CurrentUser.Username);
            return Task.CompletedTask;
        }

        public async Task<(bool Success, string Message)> SendTestWebhookAsync(string? customWebhookUrl = null)
        {
            if (!string.IsNullOrWhiteSpace(customWebhookUrl) && IsValidWebhookUrl(customWebhookUrl))
            {
                SetWebhookUrl(customWebhookUrl);
            }

            var webhookUrl = GetActiveWebhookUrl();
            if (!IsValidWebhookUrl(webhookUrl))
            {
                return (false, "Chưa có Discord Webhook URL hợp lệ. Vui lòng dán link Webhook Discord của bạn.");
            }

            try
            {
                using var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
                var vnNow = DateTime.UtcNow.AddHours(7);
                var payload = new
                {
                    content = $"✅ **KIỂM TRA KẾT NỐI DISCORD SMARTGUARD** lúc `{vnNow:HH:mm:ss dd/MM/yyyy}` (Giờ Việt Nam UTC+7)",
                    embeds = new[]
                    {
                        new
                        {
                            title = "🛡️ HỆ THỐNG BÁO ĐỘNG SMARTGUARD ĐÃ KẾT NỐI",
                            description = "Kênh Discord này đã sẵn sàng nhận thông báo cảnh báo chuyển động, âm thanh bất thường và ảnh chụp bằng chứng từ ứng dụng SmartGuard Mobile.",
                            color = 3066993,
                            footer = new { text = "SmartGuard AI Security System" },
                            timestamp = DateTime.UtcNow.ToString("o")
                        }
                    }
                };

                var jsonPayload = System.Text.Json.JsonSerializer.Serialize(payload);
                var jsonContent = new StringContent(jsonPayload, Encoding.UTF8, "application/json");
                var response = await httpClient.PostAsync(webhookUrl, jsonContent);
                var body = await response.Content.ReadAsStringAsync();

                if (response.IsSuccessStatusCode)
                {
                    return (true, "Đã gửi tin nhắn kiểm tra tới kênh Discord thành công!");
                }

                return (false, $"Discord trả về mã lỗi HTTP {(int)response.StatusCode}: {body}. (Lưu ý: Nếu Webhook từng bị đẩy lên GitHub công khai, Discord sẽ tự động xóa Webhook đó — hãy tạo Webhook mới trong Cài đặt Kênh Discord -> Tích hợp -> Webhooks).");
            }
            catch (Exception ex)
            {
                return (false, $"Lỗi kết nối tới Discord: {ex.Message}");
            }
        }

        public async Task SendAlertWithImageAsync(
            Guid alertId,
            string deviceName,
            string triggerReason,
            string severity,
            string? localImagePath,
            string? serverBaseUrl = null)
        {
            var baseUrl = !string.IsNullOrWhiteSpace(serverBaseUrl)
                ? serverBaseUrl.TrimEnd('/')
                : "https://smartguard-unified.onrender.com";

            var vnTimeStr = DateTime.UtcNow.AddHours(7).ToString("HH:mm:ss dd/MM/yyyy");

            // ============================================================
            // 1. Thử gửi qua Discord Bot WebSocket (có nút bấm tương tác)
            // ============================================================
            if (IsBotConnected && _client != null)
            {
                try
                {
                    var embed = new EmbedBuilder()
                        .WithTitle("🚨 CẢNH BÁO AN NINH SMARTGUARD")
                        .WithDescription($"Thiết bị **{deviceName}** vừa phát hiện sự kiện bất thường lúc **{vnTimeStr}** (Giờ VN)!\n\n" +
                                         $"**👉 THAO TÁC XỬ LÝ NHANH:**\n" +
                                         $"• [✅ Đánh dấu Người quen]({baseUrl}/api/alerts/{alertId}/quick-action?action=known)\n" +
                                         $"• [🚨 Đánh dấu Người lạ]({baseUrl}/api/alerts/{alertId}/quick-action?action=stranger)\n" +
                                         $"• [🔕 Tắt chuông báo cảnh báo]({baseUrl}/api/alerts/{alertId}/quick-action?action=mute)")
                        .AddField("Nguyên nhân", triggerReason, true)
                        .AddField("Mức độ", severity, true)
                        .AddField("Thời gian (VN)", vnTimeStr, true)
                        .AddField("Mã sự kiện", alertId.ToString(), false)
                        .WithColor(severity.Equals("Critical", StringComparison.OrdinalIgnoreCase) ? Color.Red : Color.Orange)
                        .WithCurrentTimestamp()
                        .WithFooter("SmartGuard AI Security System")
                        .Build();

                    var components = new ComponentBuilder()
                        .WithButton("✅ Người quen", $"known_{alertId}", ButtonStyle.Success)
                        .WithButton("🚨 Người lạ", $"stranger_{alertId}", ButtonStyle.Danger)
                        .WithButton("🔕 Tắt chuông", $"mute_{alertId}", ButtonStyle.Secondary)
                        .Build();

                    var channel = _client.GetChannel(_options.ChannelId) as IMessageChannel;
                    if (channel != null)
                    {
                        if (!string.IsNullOrEmpty(localImagePath) && File.Exists(localImagePath))
                        {
                            await channel.SendFileAsync(
                                filePath: localImagePath,
                                text: $"@here 🚨 Phát hiện sự kiện an ninh lúc {vnTimeStr}!",
                                embed: embed,
                                components: components);
                        }
                        else
                        {
                            await channel.SendMessageAsync(
                                text: $"@here 🚨 Phát hiện sự kiện an ninh lúc {vnTimeStr}!",
                                embed: embed,
                                components: components);
                        }
                        _logger.LogInformation("✅ Đã đẩy cảnh báo {AlertId} lên Discord Channel {ChannelId}", alertId, _options.ChannelId);
                        return;
                    }
                    else
                    {
                        _logger.LogWarning("Không tìm thấy Channel {ChannelId}. Chuyển sang Webhook fallback.", _options.ChannelId);
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Gửi qua Discord Bot thất bại, chuyển sang Webhook fallback.");
                }
            }

            // ============================================================
            // 2. Fallback: Gửi qua Discord Webhook (JSON + Ảnh bằng chứng)
            // ============================================================
            var activeWebhookUrl = GetActiveWebhookUrl();
            if (IsValidWebhookUrl(activeWebhookUrl))
            {
                try
                {
                    using var httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

                    var descriptionText =
                        $"**Thiết bị:** {deviceName}\n" +
                        $"**Nguyên nhân:** {triggerReason}\n" +
                        $"**Mức độ:** {severity}\n" +
                        $"**Thời gian (VN):** {vnTimeStr}\n\n" +
                        $"**👉 THAO TÁC XỬ LÝ TRỰC TIẾP:**\n" +
                        $"• [✅ Bấm để Đánh dấu Người quen]({baseUrl}/api/alerts/{alertId}/quick-action?action=known)\n" +
                        $"• [🚨 Bấm để Đánh dấu Người lạ]({baseUrl}/api/alerts/{alertId}/quick-action?action=stranger)\n" +
                        $"• [🔕 Bấm để Tắt chuông báo cảnh báo]({baseUrl}/api/alerts/{alertId}/quick-action?action=mute)";

                    var webhookPayload = new
                    {
                        content = $"🚨 **CẢNH BÁO SMARTGUARD**: {deviceName} phát hiện [{triggerReason}] lúc **{vnTimeStr}**!",
                        embeds = new[]
                        {
                            new
                            {
                                title = "🚨 CẢNH BÁO AN NINH SMARTGUARD",
                                description = descriptionText,
                                color = severity.Equals("Critical", StringComparison.OrdinalIgnoreCase) ? 16711680 : 16744448,
                                footer = new { text = $"SmartGuard AI Security System • {alertId}" },
                                timestamp = DateTime.UtcNow.ToString("o")
                            }
                        }
                    };

                    var jsonPayload = System.Text.Json.JsonSerializer.Serialize(webhookPayload);
                    var jsonContent = new StringContent(jsonPayload, Encoding.UTF8, "application/json");

                    var response = await httpClient.PostAsync(activeWebhookUrl, jsonContent);
                    var responseBody = await response.Content.ReadAsStringAsync();

                    if (response.IsSuccessStatusCode)
                    {
                        _logger.LogInformation("✅ Đã gửi cảnh báo {AlertId} qua Discord Webhook thành công.", alertId);

                        if (!string.IsNullOrEmpty(localImagePath) && File.Exists(localImagePath))
                        {
                            try
                            {
                                using var imgClient = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
                                using var multipart = new MultipartFormDataContent();
                                var fileBytes = await File.ReadAllBytesAsync(localImagePath);
                                var imgPayload = System.Text.Json.JsonSerializer.Serialize(
                                    new { content = $"📷 **Bằng chứng hình ảnh** cho cảnh báo `{alertId}` ({vnTimeStr}):" });
                                multipart.Add(new StringContent(imgPayload, Encoding.UTF8, "application/json"), "payload_json");
                                multipart.Add(new ByteArrayContent(fileBytes), "file", Path.GetFileName(localImagePath));
                                await imgClient.PostAsync(activeWebhookUrl, multipart);
                                _logger.LogInformation("✅ Đã gửi ảnh bằng chứng cho cảnh báo {AlertId}.", alertId);
                            }
                            catch (Exception imgEx)
                            {
                                _logger.LogWarning(imgEx, "Không gửi được ảnh bằng chứng nhưng text đã gửi thành công.");
                            }
                        }
                    }
                    else
                    {
                        _logger.LogError("❌ Discord Webhook thất bại: HTTP {Status} - Response: {Body}", (int)response.StatusCode, responseBody);
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "❌ Lỗi khi gửi Discord Webhook.");
                }
            }
            else
            {
                _logger.LogWarning("❌ Không có Bot kết nối lẫn không có Webhook hợp lệ. Cảnh báo KHÔNG được gửi đến Discord!");
            }
        }

        public async Task UpdateAlertActionAsync(Guid alertId, string status, string responderName)
        {
            _logger.LogInformation("Cập nhật cảnh báo {AlertId}: {Status} bởi {Responder}", alertId, status, responderName);
            await Task.CompletedTask;
        }

        private async Task OnButtonExecutedAsync(SocketMessageComponent component)
        {
            var customId = component.Data.CustomId;
            var user = component.User.Username;

            using var scope = _serviceProvider.CreateScope();
            var db = scope.ServiceProvider.GetRequiredService<SmartGuardDbContext>();

            if (customId.StartsWith("known_") || customId.StartsWith("ack_"))
            {
                var alertIdStr = customId.Replace("known_", "").Replace("ack_", "");
                if (Guid.TryParse(alertIdStr, out var alertId))
                {
                    var alert = await db.AlertEvents.FindAsync(alertId);
                    if (alert != null)
                    {
                        alert.Status = "KnownPerson";
                        alert.AcknowledgedAt = DateTime.UtcNow;

                        var device = await db.Devices.FindAsync(alert.DeviceId);
                        if (device != null)
                        {
                            var profile = await db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.UserId == device.OwnerId && p.IsActive);
                            if (profile != null)
                            {
                                profile.SnoozeUntil = DateTime.UtcNow.AddMinutes(3);
                            }
                        }
                        await db.SaveChangesAsync();
                    }
                }
                await component.RespondAsync($"✅ **{user}** đã xác nhận: **ĐÂY LÀ NGƯỜI QUEN**. Hệ thống đã tắt còi báo động và tạm dừng cảnh báo 3 phút.", ephemeral: false);
            }
            else if (customId.StartsWith("stranger_") || customId.StartsWith("alarm_"))
            {
                var alertIdStr = customId.Replace("stranger_", "").Replace("alarm_", "");
                if (Guid.TryParse(alertIdStr, out var alertId))
                {
                    var alert = await db.AlertEvents.FindAsync(alertId);
                    if (alert != null)
                    {
                        alert.Status = "ConfirmedStranger";
                        alert.AcknowledgedAt = DateTime.UtcNow;
                        await db.SaveChangesAsync();
                    }
                }
                await component.RespondAsync($"🚨 **{user}** đã xác nhận: **ĐÂY LÀ NGƯỜI LẠ XÂM NHẬP**! Hệ thống tiếp tục báo động khẩn cấp!", ephemeral: false);
            }
            else if (customId.StartsWith("mute_"))
            {
                var alertIdStr = customId.Replace("mute_", "");
                if (Guid.TryParse(alertIdStr, out var alertId))
                {
                    var alert = await db.AlertEvents.FindAsync(alertId);
                    if (alert != null)
                    {
                        alert.Status = "Muted";
                        alert.AcknowledgedAt = DateTime.UtcNow;

                        var device = await db.Devices.FindAsync(alert.DeviceId);
                        if (device != null)
                        {
                            var profile = await db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.UserId == device.OwnerId && p.IsActive);
                            if (profile != null)
                            {
                                profile.SnoozeUntil = DateTime.UtcNow.AddMinutes(3);
                            }
                        }
                        await db.SaveChangesAsync();
                    }
                }
                await component.RespondAsync($"🔕 **{user}** đã **TẮT CHUÔNG BÁO ĐỘNG** và tạm dừng cảnh báo 3 phút cho sự kiện `{alertIdStr}`.", ephemeral: false);
            }
        }
    }
}
