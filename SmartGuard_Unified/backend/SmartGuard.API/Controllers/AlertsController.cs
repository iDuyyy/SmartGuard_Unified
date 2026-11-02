using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SmartGuard.API.Data;
using SmartGuard.API.DTOs;
using SmartGuard.API.Models;
using SmartGuard.API.Services.Discord;
using SmartGuard.API.Services.Adaptive;

namespace SmartGuard.API.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    public class AlertsController : ControllerBase
    {
        private readonly SmartGuardDbContext _db;
        private readonly IDiscordAlertService _discordService;
        private readonly IAdaptiveRuleEngine _ruleEngine;
        private readonly IWebHostEnvironment _env;
        private readonly ILogger<AlertsController> _logger;

        public AlertsController(
            SmartGuardDbContext db,
            IDiscordAlertService discordService,
            IAdaptiveRuleEngine ruleEngine,
            IWebHostEnvironment env,
            ILogger<AlertsController> logger)
        {
            _db = db;
            _discordService = discordService;
            _ruleEngine = ruleEngine;
            _env = env;
            _logger = logger;
        }

        private Guid CurrentUserId =>
            Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub"), out var id)
                ? id
                : Guid.Empty;

        private bool IsAdmin => User.IsInRole("Admin");

        [HttpPost("trigger")]
        public async Task<IActionResult> TriggerAlert([FromBody] TriggerAlertDto dto)
        {
            var device = await _db.Devices.Include(d => d.Zone).FirstOrDefaultAsync(d => d.Id == dto.DeviceId);
            if (device == null) return NotFound(new { message = "Thiết bị không tồn tại." });

            if (!device.IsArmed)
            {
                _logger.LogInformation("Thiết bị {DeviceName} đang ở trạng thái Tắt cảnh giác (Disarmed). Bỏ qua cảnh báo.", device.Name);
                return Ok(new { message = "Thiết bị đang tắt cảnh giác. Cảnh báo không phát động." });
            }

            var triggerReason = string.IsNullOrWhiteSpace(dto.TriggerReason) ? "CHUYEN_DONG" : dto.TriggerReason.Trim();
            var severity = string.IsNullOrWhiteSpace(dto.Severity) ? "Warning" : dto.Severity.Trim();

            // Đánh giá kịch bản thích ứng (Smart Adaptive Security Evaluation)
            var evaluation = await _ruleEngine.EvaluateAlertAsync(device, triggerReason, dto.TriggerScore, severity);
            if (!evaluation.ShouldTriggerAlert)
            {
                return Ok(new
                {
                    message = evaluation.SuppressionReason ?? "Cảnh báo được bỏ qua bởi chế độ an ninh thích ứng.",
                    suppressed = true
                });
            }

            var alert = new AlertEvent
            {
                DeviceId = device.Id,
                TriggerReason = triggerReason,
                TriggerScore = dto.TriggerScore,
                Severity = severity,
                ImageUrl = dto.ImageUrl,
                AdaptiveReason = evaluation.ReasonExplanation,
                Status = "Triggered",
                TriggeredAt = DateTime.UtcNow
            };

            _db.AlertEvents.Add(alert);
            device.LastSeenAt = DateTime.UtcNow;
            await _db.SaveChangesAsync();

            _logger.LogWarning("🚨 CẢNH BÁO MỚI [{Reason}] từ thiết bị {DeviceName} ({Severity}): {AdaptiveReason}",
                alert.TriggerReason, device.Name, alert.Severity, alert.AdaptiveReason);

            // Kiểm tra đường dẫn ảnh cục bộ nếu có để gửi Discord
            string? localImagePath = null;
            if (!string.IsNullOrEmpty(dto.ImageUrl))
            {
                var cleanPath = dto.ImageUrl.TrimStart('/', '\\').Replace('/', Path.DirectorySeparatorChar);
                var fullPath = Path.Combine(_env.WebRootPath ?? Path.Combine(_env.ContentRootPath, "wwwroot"), cleanPath);
                if (System.IO.File.Exists(fullPath))
                {
                    localImagePath = fullPath;
                }
            }

            // Gửi cảnh báo bất đồng bộ lên Discord nếu chế độ thích ứng cho phép
            if (evaluation.EnableDiscordNotification)
            {
                var baseUrl = HttpContext?.Request?.Host.HasValue == true
                    ? $"{Request.Scheme}://{Request.Host}"
                    : null;
                _ = Task.Run(async () =>
                {
                    try
                    {
                        await _discordService.SendAlertWithImageAsync(
                            alert.Id,
                            device.Name,
                            $"{alert.TriggerReason} - {evaluation.ReasonExplanation}",
                            alert.Severity,
                            localImagePath,
                            baseUrl);
                    }
                    catch (Exception ex)
                    {
                        _logger.LogError(ex, "Lỗi gửi cảnh báo lên Discord");
                    }
                });
            }

            return Ok(new
            {
                message = "Đã tiếp nhận cảnh báo thành công!",
                id = alert.Id,
                alertId = alert.Id,
                status = alert.Status,
                triggeredAt = alert.TriggeredAt,
                adaptiveReason = alert.AdaptiveReason
            });
        }

        [HttpGet("history")]
        public async Task<IActionResult> GetAlertHistory([FromQuery] int limit = 50)
        {
            var userId = CurrentUserId;

            var alerts = await _db.AlertEvents
                .Include(a => a.Device)
                .ThenInclude(d => d!.Zone)
                .Where(a => IsAdmin || (a.Device != null && a.Device.OwnerId == userId) ||
                    (a.Device != null && _db.MemberAccesses.Any(m =>
                        m.MemberUserId == userId &&
                        m.OwnerId == a.Device.OwnerId &&
                        (m.DeviceId == a.DeviceId || m.DeviceId == null))))
                .OrderByDescending(a => a.TriggeredAt)
                .Take(Math.Clamp(limit, 1, 200))
                .Select(a => new AlertResponseDto(
                    a.Id,
                    a.DeviceId,
                    a.Device != null ? a.Device.Name : "N/A",
                    a.Device != null && a.Device.Zone != null ? a.Device.Zone.Name : null,
                    a.TriggerReason,
                    a.TriggerScore,
                    a.Severity,
                    a.Status,
                    a.ImageUrl,
                    a.TriggeredAt,
                    a.AcknowledgedAt,
                    a.AdaptiveReason
                ))
                .ToListAsync();

            return Ok(alerts);
        }

        [HttpGet("device/{deviceId:guid}/status")]
        [AllowAnonymous]
        public async Task<IActionResult> GetDeviceAlertStatus(Guid deviceId)
        {
            var device = await _db.Devices.FirstOrDefaultAsync(d => d.Id == deviceId);
            if (device == null) return NotFound(new { message = "Thiết bị không tồn tại." });

            var activeProfile = await _db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.UserId == device.OwnerId && p.IsActive);
            bool isSnoozed = activeProfile?.SnoozeUntil.HasValue == true && activeProfile.SnoozeUntil.Value > DateTime.UtcNow;
            int snoozeRemainingSeconds = isSnoozed ? (int)(activeProfile!.SnoozeUntil!.Value - DateTime.UtcNow).TotalSeconds : 0;

            var latestAlert = await _db.AlertEvents
                .Where(a => a.DeviceId == deviceId)
                .OrderByDescending(a => a.TriggeredAt)
                .Select(a => new
                {
                    a.Id,
                    a.Status,
                    a.TriggerReason,
                    a.TriggeredAt,
                    a.AcknowledgedAt
                })
                .FirstOrDefaultAsync();

            return Ok(new
            {
                deviceId = device.Id,
                isArmed = device.IsArmed,
                isSnoozed = isSnoozed,
                snoozeRemainingSeconds = snoozeRemainingSeconds,
                latestAlert = latestAlert
            });
        }

        [HttpPost("{id:guid}/action")]
        public async Task<IActionResult> AcknowledgeAlert(Guid id, [FromBody] AcknowledgeAlertDto dto)
        {
            var userId = CurrentUserId;
            var alert = await _db.AlertEvents.Include(a => a.Device).FirstOrDefaultAsync(a => a.Id == id);
            if (alert == null) return NotFound(new { message = "Không tìm thấy cảnh báo." });

            // Kiểm tra quyền xác nhận cảnh báo (Admin, Chủ sở hữu, hoặc Thành viên được cấp quyền CanAcknowledge)
            if (!IsAdmin && alert.Device != null && alert.Device.OwnerId != userId)
            {
                var hasMemberPerm = await _db.MemberAccesses.AnyAsync(m =>
                    m.MemberUserId == userId &&
                    m.OwnerId == alert.Device.OwnerId &&
                    m.CanAcknowledge &&
                    (m.DeviceId == alert.DeviceId || m.DeviceId == null));

                if (!hasMemberPerm)
                    return Forbid();
            }

            var act = (dto.Action ?? string.Empty).Trim().ToLowerInvariant();
            if (act == "known" || act == "knownperson")
            {
                alert.Status = "KnownPerson";
            }
            else if (act == "mute" || act == "muted")
            {
                alert.Status = "Muted";
            }
            else if (act == "stranger" || act == "confirmedstranger")
            {
                alert.Status = "ConfirmedStranger";
            }
            else if (act == "dismiss")
            {
                alert.Status = "Dismissed";
            }
            else
            {
                alert.Status = "Confirmed";
            }

            alert.AcknowledgedBy = userId;
            alert.AcknowledgedAt = DateTime.UtcNow;

            // Tự động tạm dừng cảnh báo 3 phút nếu là Người quen hoặc Tắt chuông
            if (alert.Status == "KnownPerson" || alert.Status == "Muted")
            {
                if (alert.Device != null)
                {
                    await _ruleEngine.InitializeDefaultProfilesForUserAsync(alert.Device.OwnerId);
                    var activeProfile = await _db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.UserId == alert.Device.OwnerId && p.IsActive);
                    if (activeProfile != null)
                    {
                        activeProfile.SnoozeUntil = DateTime.UtcNow.AddMinutes(3);
                    }
                }
            }

            await _db.SaveChangesAsync();

            var username = User.FindFirstValue(ClaimTypes.Name) ?? "Người dùng";
            await _discordService.UpdateAlertActionAsync(alert.Id, alert.Status, username);

            return Ok(new { message = $"Đã xử lý cảnh báo thành công [{alert.Status}].", alertId = alert.Id, status = alert.Status });
        }

        [HttpGet("{id:guid}/quick-action")]
        [AllowAnonymous]
        public async Task<IActionResult> QuickAction(Guid id, [FromQuery] string action)
        {
            var alert = await _db.AlertEvents.Include(a => a.Device).FirstOrDefaultAsync(a => a.Id == id);
            if (alert == null)
            {
                return Content("<h2>Không tìm thấy mã cảnh báo này trong hệ thống.</h2>", "text/html; charset=utf-8");
            }

            string title;
            string message;
            string color;

            switch (action?.ToLowerInvariant())
            {
                case "known":
                    alert.Status = "KnownPerson";
                    alert.AcknowledgedAt = DateTime.UtcNow;
                    title = "✅ ĐÃ XÁC NHẬN: NGƯỜI QUEN";
                    message = "Hệ thống đã ghi nhận đối tượng là người quen, còi báo động đã được tắt và tạm dừng cảnh báo 3 phút.";
                    color = "#16a34a";
                    if (alert.Device != null)
                    {
                        await _ruleEngine.InitializeDefaultProfilesForUserAsync(alert.Device.OwnerId);
                        var activeProfile = await _db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.UserId == alert.Device.OwnerId && p.IsActive);
                        if (activeProfile != null)
                        {
                            activeProfile.SnoozeUntil = DateTime.UtcNow.AddMinutes(3);
                        }
                    }
                    break;
                case "stranger":
                    alert.Status = "ConfirmedStranger";
                    alert.AcknowledgedAt = DateTime.UtcNow;
                    title = "🚨 ĐÃ XÁC NHẬN: NGƯỜI LẠ XÂM NHẬP";
                    message = "Hệ thống xác nhận có xâm nhập trái phép! Toàn bộ cơ chế báo động và lưu trữ bằng chứng đang được duy trì.";
                    color = "#dc2626";
                    break;
                case "mute":
                default:
                    alert.Status = "Muted";
                    alert.AcknowledgedAt = DateTime.UtcNow;
                    title = "🔕 ĐÃ TẮT CHUÔNG BÁO ĐỘNG";
                    message = "Còi báo động đã được tắt và tạm dừng cảnh báo 3 phút.";
                    color = "#2563eb";
                    if (alert.Device != null)
                    {
                        await _ruleEngine.InitializeDefaultProfilesForUserAsync(alert.Device.OwnerId);
                        var activeProfile = await _db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.UserId == alert.Device.OwnerId && p.IsActive);
                        if (activeProfile != null)
                        {
                            activeProfile.SnoozeUntil = DateTime.UtcNow.AddMinutes(3);
                        }
                    }
                    break;
            }

            await _db.SaveChangesAsync();
            await _discordService.UpdateAlertActionAsync(alert.Id, alert.Status, "Discord Quick-Action");

            var html = $@"
<!DOCTYPE html>
<html lang='vi'>
<head>
    <meta charset='UTF-8'>
    <meta name='viewport' content='width=device-width, initial-scale=1.0'>
    <title>{title}</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #f8fafc; display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; padding: 20px; box-sizing: border-box; }}
        .card {{ background: #1e293b; border-radius: 16px; padding: 32px 24px; max-width: 450px; width: 100%; text-align: center; box-shadow: 0 10px 25px rgba(0,0,0,0.5); border-top: 6px solid {color}; }}
        h1 {{ font-size: 20px; color: {color}; margin-top: 0; }}
        p {{ font-size: 15px; color: #cbd5e1; line-height: 1.6; }}
        .badge {{ display: inline-block; padding: 6px 14px; background: rgba(255,255,255,0.08); border-radius: 20px; font-size: 13px; color: #94a3b8; margin-top: 15px; }}
    </style>
</head>
<body>
    <div class='card'>
        <h1>{title}</h1>
        <p>{message}</p>
        <div class='badge'>Thiết bị: {alert.Device?.Name ?? "SmartGuard Camera"} | Sự kiện: {alert.TriggerReason}</div>
    </div>
</body>
</html>";

            return Content(html, "text/html; charset=utf-8");
        }
    }
}
