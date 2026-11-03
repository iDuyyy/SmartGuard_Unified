using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SmartGuard.API.Data;
using SmartGuard.API.DTOs;
using SmartGuard.API.Models;

namespace SmartGuard.API.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    [Authorize]
    public class DevicesController : ControllerBase
    {
        private readonly SmartGuardDbContext _db;
        private readonly ILogger<DevicesController> _logger;

        public DevicesController(SmartGuardDbContext db, ILogger<DevicesController> logger)
        {
            _db = db;
            _logger = logger;
        }

        private Guid CurrentUserId =>
            Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub"), out var id)
                ? id
                : Guid.Empty;

        private bool IsAdmin => User.IsInRole("Admin");

        [HttpGet]
        public async Task<IActionResult> GetDevices()
        {
            var userId = CurrentUserId;
            if (userId == Guid.Empty && !IsAdmin) return Unauthorized();

            // 1. Lấy danh sách thiết bị sở hữu trực tiếp (hoặc toàn bộ nếu là Admin)
            var ownedDevices = await _db.Devices
                .Include(d => d.Zone)
                .Where(d => IsAdmin || d.OwnerId == userId)
                .Select(d => new DeviceResponseDto(
                    d.Id,
                    d.OwnerId,
                    d.ZoneId,
                    d.Zone != null ? d.Zone.Name : null,
                    d.Name,
                    d.DeviceCode,
                    d.Description,
                    d.IsArmed,
                    d.NoiseThreshold,
                    d.MotionThreshold,
                    d.RegisteredAt,
                    d.LastSeenAt
                ))
                .ToListAsync();

            if (IsAdmin) return Ok(ownedDevices);

            // 2. Lấy thêm các thiết bị được chia sẻ qua MemberAccesses (cả chia sẻ theo DeviceId cụ thể lẫn toàn bộ thiết bị của Owner khi DeviceId == null)
            var memberAccesses = await _db.MemberAccesses
                .Where(m => m.MemberUserId == userId)
                .Select(m => new { m.OwnerId, m.DeviceId })
                .ToListAsync();

            if (memberAccesses.Count > 0)
            {
                var ownedIds = ownedDevices.Select(o => o.Id).ToList();
                var fullAccessOwnerIds = memberAccesses
                    .Where(m => m.DeviceId == null)
                    .Select(m => m.OwnerId)
                    .Distinct()
                    .ToList();
                var specificDeviceIds = memberAccesses
                    .Where(m => m.DeviceId.HasValue)
                    .Select(m => m.DeviceId!.Value)
                    .Distinct()
                    .ToList();

                var sharedDevices = await _db.Devices
                    .Include(d => d.Zone)
                    .Where(d => !ownedIds.Contains(d.Id) &&
                                (specificDeviceIds.Contains(d.Id) || fullAccessOwnerIds.Contains(d.OwnerId)))
                    .Select(d => new DeviceResponseDto(
                        d.Id,
                        d.OwnerId,
                        d.ZoneId,
                        d.Zone != null ? d.Zone.Name : null,
                        d.Name,
                        d.DeviceCode,
                        d.Description,
                        d.IsArmed,
                        d.NoiseThreshold,
                        d.MotionThreshold,
                        d.RegisteredAt,
                        d.LastSeenAt
                    ))
                    .ToListAsync();

                ownedDevices.AddRange(sharedDevices);
            }

            // 3. Nếu người dùng mới đăng ký chưa có thiết bị nào, tự động khởi tạo 1 thiết bị Camera mặc định
            if (ownedDevices.Count == 0 && userId != Guid.Empty)
            {
                var defaultDevice = new GuardDevice
                {
                    OwnerId = userId,
                    Name = "Camera Điện Thoại SmartGuard",
                    Description = "Loại: camera | Vị trí: Cửa chính",
                    IsArmed = true,
                    NoiseThreshold = 70.0,
                    MotionThreshold = 3.5,
                    RegisteredAt = DateTime.UtcNow,
                    LastSeenAt = DateTime.UtcNow
                };
                _db.Devices.Add(defaultDevice);
                await _db.SaveChangesAsync();

                ownedDevices.Add(new DeviceResponseDto(
                    defaultDevice.Id,
                    defaultDevice.OwnerId,
                    defaultDevice.ZoneId,
                    null,
                    defaultDevice.Name,
                    defaultDevice.DeviceCode,
                    defaultDevice.Description,
                    defaultDevice.IsArmed,
                    defaultDevice.NoiseThreshold,
                    defaultDevice.MotionThreshold,
                    defaultDevice.RegisteredAt,
                    defaultDevice.LastSeenAt
                ));
            }

            return Ok(ownedDevices);
        }

        [HttpGet("{id:guid}")]
        public async Task<IActionResult> GetDevice(Guid id)
        {
            var userId = CurrentUserId;
            var device = await _db.Devices
                .Include(d => d.Zone)
                .FirstOrDefaultAsync(d => d.Id == id && (IsAdmin || d.OwnerId == userId ||
                    _db.MemberAccesses.Any(m => m.MemberUserId == userId && m.OwnerId == d.OwnerId && (m.DeviceId == id || m.DeviceId == null))));

            if (device == null) return NotFound(new { message = "Không tìm thấy thiết bị." });

            return Ok(new DeviceResponseDto(
                device.Id,
                device.OwnerId,
                device.ZoneId,
                device.Zone?.Name,
                device.Name,
                device.DeviceCode,
                device.Description,
                device.IsArmed,
                device.NoiseThreshold,
                device.MotionThreshold,
                device.RegisteredAt,
                device.LastSeenAt
            ));
        }

        [HttpPost]
        public async Task<IActionResult> CreateDevice([FromBody] CreateDeviceDto dto)
        {
            var userId = CurrentUserId;
            if (userId == Guid.Empty) return Unauthorized();

            var deviceName = (dto.Name ?? string.Empty).Trim();
            if (string.IsNullOrWhiteSpace(deviceName))
                return BadRequest(new { message = "Tên thiết bị không được để trống." });

            string? zoneName = null;
            if (dto.ZoneId.HasValue)
            {
                var zone = await _db.Zones.FirstOrDefaultAsync(z => z.Id == dto.ZoneId.Value && (IsAdmin || z.OwnerId == userId));
                if (zone != null) zoneName = zone.Name;
            }

            var device = new GuardDevice
            {
                OwnerId = userId,
                Name = deviceName,
                Description = dto.Description?.Trim() ?? string.Empty,
                ZoneId = dto.ZoneId,
                NoiseThreshold = dto.NoiseThreshold,
                MotionThreshold = dto.MotionThreshold,
                IsArmed = true
            };

            _db.Devices.Add(device);
            await _db.SaveChangesAsync();

            _logger.LogInformation("Thiết bị mới {DeviceName} ({DeviceCode}) đã đăng ký bởi User {UserId}", device.Name, device.DeviceCode, device.OwnerId);

            return CreatedAtAction(nameof(GetDevice), new { id = device.Id }, new DeviceResponseDto(
                device.Id,
                device.OwnerId,
                device.ZoneId,
                zoneName,
                device.Name,
                device.DeviceCode,
                device.Description,
                device.IsArmed,
                device.NoiseThreshold,
                device.MotionThreshold,
                device.RegisteredAt,
                device.LastSeenAt
            ));
        }

        [HttpPut("{id:guid}")]
        public async Task<IActionResult> UpdateDevice(Guid id, [FromBody] UpdateDeviceDto dto)
        {
            var userId = CurrentUserId;
            var device = await _db.Devices.FirstOrDefaultAsync(d => d.Id == id && (IsAdmin || d.OwnerId == userId));
            if (device == null) return NotFound(new { message = "Không tìm thấy thiết bị hoặc không có quyền." });

            if (!string.IsNullOrWhiteSpace(dto.Name)) device.Name = dto.Name.Trim();
            if (dto.Description != null) device.Description = dto.Description.Trim();
            if (dto.ZoneId.HasValue) device.ZoneId = dto.ZoneId.Value;
            if (dto.IsArmed.HasValue) device.IsArmed = dto.IsArmed.Value;
            if (dto.NoiseThreshold.HasValue) device.NoiseThreshold = dto.NoiseThreshold.Value;
            if (dto.MotionThreshold.HasValue) device.MotionThreshold = dto.MotionThreshold.Value;

            await _db.SaveChangesAsync();
            return Ok(new { message = "Cập nhật thiết bị thành công.", deviceId = device.Id });
        }

        [HttpPatch("{id:guid}/toggle-arm")]
        public async Task<IActionResult> ToggleArm(Guid id)
        {
            var userId = CurrentUserId;
            var device = await _db.Devices.FirstOrDefaultAsync(d => d.Id == id && (IsAdmin || d.OwnerId == userId ||
                _db.MemberAccesses.Any(m => m.MemberUserId == userId && m.OwnerId == d.OwnerId && m.CanAcknowledge && (m.DeviceId == id || m.DeviceId == null))));

            if (device == null) return NotFound(new { message = "Không tìm thấy thiết bị." });

            device.IsArmed = !device.IsArmed;
            device.LastSeenAt = DateTime.UtcNow;
            await _db.SaveChangesAsync();

            return Ok(new { isArmed = device.IsArmed, message = device.IsArmed ? "Đã bật chế độ cảnh giác!" : "Đã tắt cảnh giác." });
        }

        [HttpDelete("{id:guid}")]
        public async Task<IActionResult> DeleteDevice(Guid id)
        {
            var userId = CurrentUserId;
            var device = await _db.Devices.FirstOrDefaultAsync(d => d.Id == id && (IsAdmin || d.OwnerId == userId));
            if (device == null) return NotFound(new { message = "Không tìm thấy thiết bị hoặc không có quyền." });

            // Dọn dẹp EvidenceImages liên kết với thiết bị này trước khi xóa để không bị lỗi FK_EvidenceImages_AlertEvents
            var evidences = await _db.EvidenceImages.Where(e => e.DeviceId == id).ToListAsync();
            if (evidences.Count > 0) _db.EvidenceImages.RemoveRange(evidences);

            var memberAccesses = await _db.MemberAccesses.Where(m => m.DeviceId == id).ToListAsync();
            if (memberAccesses.Count > 0) _db.MemberAccesses.RemoveRange(memberAccesses);

            _db.Devices.Remove(device);
            await _db.SaveChangesAsync();

            return Ok(new { message = "Đã xóa thiết bị thành công." });
        }

        [HttpPost("pair")]
        public async Task<IActionResult> PairDevice([FromBody] JsonElement body, [FromQuery] string? deviceCode = null)
        {
            string? rawCode = deviceCode;
            if (string.IsNullOrWhiteSpace(rawCode))
            {
                if (body.ValueKind == JsonValueKind.String)
                {
                    rawCode = body.GetString();
                }
                else if (body.ValueKind == JsonValueKind.Object)
                {
                    if (body.TryGetProperty("deviceCode", out var p1) && p1.ValueKind == JsonValueKind.String)
                        rawCode = p1.GetString();
                    else if (body.TryGetProperty("code", out var p2) && p2.ValueKind == JsonValueKind.String)
                        rawCode = p2.GetString();
                }
            }

            if (string.IsNullOrWhiteSpace(rawCode))
                return BadRequest(new { message = "Vui lòng cung cấp mã thiết bị (deviceCode)." });

            var code = rawCode.Trim().ToUpperInvariant();
            var device = await _db.Devices.FirstOrDefaultAsync(d => d.DeviceCode == code);
            if (device == null) return NotFound(new { message = "Mã thiết bị không tồn tại." });

            device.LastSeenAt = DateTime.UtcNow;
            await _db.SaveChangesAsync();

            return Ok(new { message = "Ghép nối thiết bị thành công!", deviceId = device.Id, deviceName = device.Name });
        }
    }
}
