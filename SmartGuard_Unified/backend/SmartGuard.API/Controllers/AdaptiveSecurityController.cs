using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SmartGuard.API.Data;
using SmartGuard.API.DTOs;
using SmartGuard.API.Models;
using SmartGuard.API.Services.Adaptive;

namespace SmartGuard.API.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    [Route("api/adaptive")]
    [Authorize]
    public class AdaptiveSecurityController : ControllerBase
    {
        private readonly SmartGuardDbContext _db;
        private readonly IAdaptiveRuleEngine _ruleEngine;
        private readonly ILogger<AdaptiveSecurityController> _logger;

        public AdaptiveSecurityController(
            SmartGuardDbContext db,
            IAdaptiveRuleEngine ruleEngine,
            ILogger<AdaptiveSecurityController> logger)
        {
            _db = db;
            _ruleEngine = ruleEngine;
            _logger = logger;
        }

        private Guid CurrentUserId =>
            Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub"), out var id)
                ? id
                : Guid.Empty;

        [HttpGet("profiles")]
        public async Task<IActionResult> GetProfiles()
        {
            var userId = CurrentUserId;
            if (userId == Guid.Empty) return Unauthorized();

            // Đảm bảo người dùng luôn có sẵn 3 chế độ mặc định (Home, Away, Night) và đồng bộ quy tắc cho mọi phân vùng mới
            await _ruleEngine.InitializeDefaultProfilesForUserAsync(userId);

            var profiles = await _db.AdaptiveProfiles
                .Include(p => p.ZoneRules!)
                .ThenInclude(r => r.Zone)
                .Where(p => p.UserId == userId)
                .OrderBy(p => p.ModeName == "Home" ? 0 : (p.ModeName == "Away" ? 1 : 2))
                .Select(p => new AdaptiveProfileDto(
                    p.Id,
                    p.ModeName,
                    p.DisplayName,
                    p.Description,
                    p.IsActive,
                    p.ActiveFrom,
                    p.ActiveTo,
                    p.BehaviorOnDisconnect,
                    p.SnoozeUntil,
                    p.SnoozeUntil.HasValue && p.SnoozeUntil.Value > DateTime.UtcNow,
                    p.ZoneRules != null
                        ? p.ZoneRules.Select(r => new AdaptiveZoneRuleDto(
                            r.Id,
                            r.ZoneId,
                            r.Zone != null ? r.Zone.Name : "Khu vực",
                            r.EnableMonitoring,
                            r.EnableAlarmSound,
                            r.EnableDiscordNotification,
                            r.CustomSensitivity
                        )).ToList()
                        : new List<AdaptiveZoneRuleDto>()
                ))
                .ToListAsync();

            return Ok(profiles);
        }

        [HttpPost("profiles/{id:guid}/activate")]
        public async Task<IActionResult> ActivateProfile(Guid id)
        {
            var userId = CurrentUserId;
            var target = await _db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.Id == id && p.UserId == userId);
            if (target == null) return NotFound(new { message = "Không tìm thấy chế độ an ninh." });

            var allProfiles = await _db.AdaptiveProfiles.Where(p => p.UserId == userId).ToListAsync();
            foreach (var p in allProfiles)
            {
                p.IsActive = (p.Id == id);
            }

            await _db.SaveChangesAsync();

            _logger.LogInformation("Người dùng {UserId} đã chuyển sang chế độ [{ModeName}]", userId, target.DisplayName);

            return Ok(new
            {
                message = $"Đã kích hoạt chế độ [{target.DisplayName}] thành công!",
                activeProfileId = target.Id,
                modeName = target.ModeName
            });
        }

        [HttpPut("profiles/{id:guid}")]
        public async Task<IActionResult> UpdateProfile(Guid id, [FromBody] UpdateAdaptiveProfileDto dto)
        {
            var userId = CurrentUserId;
            var profile = await _db.AdaptiveProfiles
                .Include(p => p.ZoneRules)
                .FirstOrDefaultAsync(p => p.Id == id && p.UserId == userId);

            if (profile == null) return NotFound(new { message = "Không tìm thấy chế độ an ninh." });

            if (!string.IsNullOrWhiteSpace(dto.DisplayName)) profile.DisplayName = dto.DisplayName.Trim();
            if (dto.Description != null) profile.Description = dto.Description.Trim();
            if (!string.IsNullOrWhiteSpace(dto.ActiveFrom)) profile.ActiveFrom = dto.ActiveFrom.Trim();
            if (!string.IsNullOrWhiteSpace(dto.ActiveTo)) profile.ActiveTo = dto.ActiveTo.Trim();
            if (!string.IsNullOrWhiteSpace(dto.BehaviorOnDisconnect)) profile.BehaviorOnDisconnect = dto.BehaviorOnDisconnect.Trim();

            // Cập nhật quy tắc từng phân vùng
            if (dto.ZoneRules != null)
            {
                profile.ZoneRules ??= new List<AdaptiveZoneRule>();
                foreach (var rDto in dto.ZoneRules)
                {
                    var existingRule = profile.ZoneRules.FirstOrDefault(r => r.ZoneId == rDto.ZoneId);
                    if (existingRule != null)
                    {
                        existingRule.EnableMonitoring = rDto.EnableMonitoring;
                        existingRule.EnableAlarmSound = rDto.EnableAlarmSound;
                        existingRule.EnableDiscordNotification = rDto.EnableDiscordNotification;
                        existingRule.CustomSensitivity = Math.Clamp(rDto.CustomSensitivity, 0.1, 3.0);
                    }
                    else
                    {
                        var newRule = new AdaptiveZoneRule
                        {
                            ProfileId = profile.Id,
                            ZoneId = rDto.ZoneId,
                            EnableMonitoring = rDto.EnableMonitoring,
                            EnableAlarmSound = rDto.EnableAlarmSound,
                            EnableDiscordNotification = rDto.EnableDiscordNotification,
                            CustomSensitivity = Math.Clamp(rDto.CustomSensitivity, 0.1, 3.0)
                        };
                        _db.AdaptiveZoneRules.Add(newRule);
                    }
                }
            }

            await _db.SaveChangesAsync();
            return Ok(new { message = "Cập nhật cấu hình chế độ thích ứng thành công." });
        }

        [HttpPost("snooze")]
        public async Task<IActionResult> SnoozeActiveProfile([FromBody] SnoozeProfileDto dto)
        {
            var userId = CurrentUserId;
            await _ruleEngine.InitializeDefaultProfilesForUserAsync(userId);
            var activeProfile = await _db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.UserId == userId && p.IsActive);
            if (activeProfile == null)
                return BadRequest(new { message = "Chưa có chế độ an ninh nào đang kích hoạt để tạm dừng." });

            var minutes = Math.Clamp(dto.Minutes, 1, 1440);
            activeProfile.SnoozeUntil = DateTime.UtcNow.AddMinutes(minutes);

            await _db.SaveChangesAsync();

            _logger.LogInformation("Người dùng {UserId} tạm dừng cảnh báo trong {Minutes} phút", userId, minutes);

            return Ok(new
            {
                message = $"Đã tạm dừng cảnh báo an ninh trong {minutes} phút (đến {activeProfile.SnoozeUntil.Value.ToLocalTime():HH:mm}).",
                snoozeUntil = activeProfile.SnoozeUntil
            });
        }

        [HttpPost("cancel-snooze")]
        public async Task<IActionResult> CancelSnooze()
        {
            var userId = CurrentUserId;
            var activeProfile = await _db.AdaptiveProfiles.FirstOrDefaultAsync(p => p.UserId == userId && p.IsActive);
            if (activeProfile == null) return NotFound(new { message = "Không tìm thấy chế độ an ninh đang kích hoạt." });

            activeProfile.SnoozeUntil = null;
            await _db.SaveChangesAsync();

            return Ok(new { message = "Đã hủy tạm dừng, hệ thống tiếp tục canh gác bình thường." });
        }
    }
}
