using Microsoft.EntityFrameworkCore;
using SmartGuard.API.Data;
using SmartGuard.API.Models;

namespace SmartGuard.API.Services.Adaptive
{
    public record AdaptiveEvaluationResult(
        bool ShouldTriggerAlert,
        bool EnableAlarmSound,
        bool EnableDiscordNotification,
        string ReasonExplanation,
        string? SuppressionReason = null
    );

    public interface IAdaptiveRuleEngine
    {
        Task<AdaptiveEvaluationResult> EvaluateAlertAsync(
            GuardDevice device,
            string triggerReason,
            double triggerScore,
            string severity);

        Task InitializeDefaultProfilesForUserAsync(Guid userId);
    }

    public class AdaptiveRuleEngine : IAdaptiveRuleEngine
    {
        private readonly SmartGuardDbContext _db;
        private readonly ILogger<AdaptiveRuleEngine> _logger;

        public AdaptiveRuleEngine(SmartGuardDbContext db, ILogger<AdaptiveRuleEngine> logger)
        {
            _db = db;
            _logger = logger;
        }

        public async Task<AdaptiveEvaluationResult> EvaluateAlertAsync(
            GuardDevice device,
            string triggerReason,
            double triggerScore,
            string severity)
        {
            var ownerId = device.OwnerId;

            // 1. Tìm chế độ an ninh đang kích hoạt (Active Profile) của chủ thiết bị
            var activeProfile = await _db.AdaptiveProfiles
                .Include(p => p.ZoneRules!)
                .ThenInclude(r => r.Zone)
                .FirstOrDefaultAsync(p => p.UserId == ownerId && p.IsActive);

            // Nếu người dùng chưa có cấu hình thích ứng, cho phép cảnh báo bình thường
            if (activeProfile == null)
            {
                return new AdaptiveEvaluationResult(
                    ShouldTriggerAlert: true,
                    EnableAlarmSound: true,
                    EnableDiscordNotification: true,
                    ReasonExplanation: $"Cảnh báo tiêu chuẩn từ thiết bị {device.Name} (Chưa kích hoạt kịch bản thích ứng).",
                    SuppressionReason: null
                );
            }

            // 2. Kiểm tra trạng thái Tạm dừng / Nghỉ tạm thời (Snooze Override)
            if (activeProfile.SnoozeUntil.HasValue && activeProfile.SnoozeUntil.Value > DateTime.UtcNow)
            {
                var remainingMinutes = (int)Math.Ceiling((activeProfile.SnoozeUntil.Value - DateTime.UtcNow).TotalMinutes);
                var reason = $"Hệ thống đang tạm dừng cảnh báo theo yêu cầu người dùng (còn {remainingMinutes} phút).";
                _logger.LogInformation("🚫 [SNOOZED] {Reason} Bỏ qua cảnh báo từ {DeviceName}", reason, device.Name);

                return new AdaptiveEvaluationResult(
                    ShouldTriggerAlert: false,
                    EnableAlarmSound: false,
                    EnableDiscordNotification: false,
                    ReasonExplanation: "Cảnh báo bị ngăn chặn bởi cơ chế tạm dừng (Snooze).",
                    SuppressionReason: reason
                );
            }

            // 3. Đánh giá quy tắc theo Phân vùng (Zone Rule)
            AdaptiveZoneRule? matchedRule = null;
            if (device.ZoneId.HasValue && activeProfile.ZoneRules != null)
            {
                matchedRule = activeProfile.ZoneRules.FirstOrDefault(r => r.ZoneId == device.ZoneId.Value);
            }

            var zoneName = device.Zone?.Name ?? matchedRule?.Zone?.Name ?? "Khu vực chung";

            // Nếu phân vùng này bị tắt giám sát trong chế độ hiện tại (Ví dụ: Phòng khách trong Chế độ Ở nhà)
            if (matchedRule != null && !matchedRule.EnableMonitoring)
            {
                var suppression = $"Chế độ [{activeProfile.DisplayName}] đã tắt giám sát khu vực [{zoneName}] để tránh làm phiền sinh hoạt.";
                _logger.LogInformation("🛡️ [ADAPTIVE FILTER] {Suppression} Bỏ qua cảnh báo từ {DeviceName}", suppression, device.Name);

                return new AdaptiveEvaluationResult(
                    ShouldTriggerAlert: false,
                    EnableAlarmSound: false,
                    EnableDiscordNotification: false,
                    ReasonExplanation: $"Khu vực [{zoneName}] được miễn trừ trong chế độ [{activeProfile.DisplayName}].",
                    SuppressionReason: suppression
                );
            }

            // Nếu người dùng chưa cấu hình ZoneRule cụ thể nhưng tên Zone là khu vực sinh hoạt và đang ở chế độ Home
            if (matchedRule == null && activeProfile.ModeName.Equals("Home", StringComparison.OrdinalIgnoreCase) && !string.IsNullOrEmpty(device.Zone?.Name))
            {
                var lowerZone = device.Zone.Name.ToLowerInvariant();
                if (lowerZone.Contains("khách") || lowerZone.Contains("bếp") || lowerZone.Contains("ngủ"))
                {
                    var suppression = $"Chế độ [{activeProfile.DisplayName}] tự động giảm cảnh báo tại khu vực sinh hoạt [{zoneName}].";
                    return new AdaptiveEvaluationResult(
                        ShouldTriggerAlert: false,
                        EnableAlarmSound: false,
                        EnableDiscordNotification: false,
                        ReasonExplanation: suppression,
                        SuppressionReason: suppression
                    );
                }
            }

            // 4. Cho phép kích hoạt cảnh báo kèm diễn giải nguồn gốc (Explainable Alert)
            var enableAlarm = matchedRule?.EnableAlarmSound ?? (activeProfile.ModeName != "Home");
            var enableDiscord = matchedRule?.EnableDiscordNotification ?? true;
            var sensitivity = matchedRule?.CustomSensitivity ?? 1.0;

            var explanation = $"Kích hoạt bởi Chế độ [{activeProfile.DisplayName}] tại khu vực [{zoneName}] (Độ nhạy x{sensitivity:0.0}).";

            return new AdaptiveEvaluationResult(
                ShouldTriggerAlert: true,
                EnableAlarmSound: enableAlarm,
                EnableDiscordNotification: enableDiscord,
                ReasonExplanation: explanation,
                SuppressionReason: null
            );
        }

        public async Task InitializeDefaultProfilesForUserAsync(Guid userId)
        {
            if (userId == Guid.Empty) return;

            var existingProfiles = await _db.AdaptiveProfiles
                .Include(p => p.ZoneRules)
                .Where(p => p.UserId == userId)
                .ToListAsync();

            var userZones = await _db.Zones.Where(z => z.OwnerId == userId).ToListAsync();

            if (existingProfiles.Count == 0)
            {
                // 1. Chế độ Ở nhà (Home)
                var homeProfile = new AdaptiveProfile
                {
                    UserId = userId,
                    ModeName = "Home",
                    DisplayName = "Ở nhà",
                    Description = "Giảm cảnh báo tại các khu vực sinh hoạt trong nhà, tập trung bảo vệ lối vào/sân ngoài.",
                    IsActive = true,
                    BehaviorOnDisconnect = "AlertOffline",
                    ZoneRules = new List<AdaptiveZoneRule>()
                };

                // 2. Chế độ Rời nhà (Away)
                var awayProfile = new AdaptiveProfile
                {
                    UserId = userId,
                    ModeName = "Away",
                    DisplayName = "Rời nhà",
                    Description = "Tăng cường giám sát tối đa trên tất cả các khu vực, gửi thông báo khẩn cấp ngay lập tức.",
                    IsActive = false,
                    BehaviorOnDisconnect = "FailSecure",
                    ZoneRules = new List<AdaptiveZoneRule>()
                };

                // 3. Chế độ Ban đêm (Night)
                var nightProfile = new AdaptiveProfile
                {
                    UserId = userId,
                    ModeName = "Night",
                    DisplayName = "Ban đêm",
                    Description = "Điều chỉnh vùng giám sát ban đêm với độ nhạy cao (x1.5), kích hoạt còi tại chỗ lập tức.",
                    IsActive = false,
                    ActiveFrom = "22:00",
                    ActiveTo = "06:00",
                    BehaviorOnDisconnect = "FailSecure",
                    ZoneRules = new List<AdaptiveZoneRule>()
                };

                foreach (var zone in userZones)
                {
                    AddZoneRuleForProfile(homeProfile, zone);
                    AddZoneRuleForProfile(awayProfile, zone);
                    AddZoneRuleForProfile(nightProfile, zone);
                }

                _db.AdaptiveProfiles.AddRange(homeProfile, awayProfile, nightProfile);
                await _db.SaveChangesAsync();
                return;
            }

            // Nếu đã có hồ sơ nhưng người dùng vừa tạo thêm Zone mới -> tự động bổ sung quy tắc cho các Zone còn thiếu
            bool changed = false;
            if (!existingProfiles.Any(p => p.IsActive))
            {
                var first = existingProfiles.FirstOrDefault(p => p.ModeName == "Home") ?? existingProfiles.First();
                first.IsActive = true;
                changed = true;
            }

            foreach (var profile in existingProfiles)
            {
                profile.ZoneRules ??= new List<AdaptiveZoneRule>();
                foreach (var zone in userZones)
                {
                    if (!profile.ZoneRules.Any(r => r.ZoneId == zone.Id))
                    {
                        var newRule = CreateZoneRuleForProfile(profile, zone);
                        _db.AdaptiveZoneRules.Add(newRule);
                        changed = true;
                    }
                }
            }

            if (changed)
            {
                await _db.SaveChangesAsync();
            }
        }

        private static void AddZoneRuleForProfile(AdaptiveProfile profile, Zone zone)
        {
            profile.ZoneRules ??= new List<AdaptiveZoneRule>();
            profile.ZoneRules.Add(CreateZoneRuleForProfile(profile, zone));
        }

        private static AdaptiveZoneRule CreateZoneRuleForProfile(AdaptiveProfile profile, Zone zone)
        {
            var lowerName = zone.Name.ToLowerInvariant();
            var isLivingArea = lowerName.Contains("khách") || lowerName.Contains("bếp") || lowerName.Contains("ngủ") || lowerName.Contains("phòng");

            if (profile.ModeName.Equals("Home", StringComparison.OrdinalIgnoreCase))
            {
                return new AdaptiveZoneRule
                {
                    ProfileId = profile.Id,
                    ZoneId = zone.Id,
                    EnableMonitoring = !isLivingArea,
                    EnableAlarmSound = false,
                    EnableDiscordNotification = true,
                    CustomSensitivity = 0.8
                };
            }
            if (profile.ModeName.Equals("Away", StringComparison.OrdinalIgnoreCase))
            {
                return new AdaptiveZoneRule
                {
                    ProfileId = profile.Id,
                    ZoneId = zone.Id,
                    EnableMonitoring = true,
                    EnableAlarmSound = true,
                    EnableDiscordNotification = true,
                    CustomSensitivity = 1.2
                };
            }
            return new AdaptiveZoneRule
            {
                ProfileId = profile.Id,
                ZoneId = zone.Id,
                EnableMonitoring = true,
                EnableAlarmSound = true,
                EnableDiscordNotification = true,
                CustomSensitivity = 1.5
            };
        }
    }
}
