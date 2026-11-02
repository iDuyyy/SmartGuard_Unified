using System.Diagnostics;
using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using SmartGuard.API.Data;
using SmartGuard.API.DTOs;
using SmartGuard.API.Models;
using SmartGuard.API.Services.Security;

namespace SmartGuard.API.Controllers
{
    [ApiController]
    [Route("api/[controller]")]
    [Authorize(Roles = "Admin")]
    public class AdminController : ControllerBase
    {
        private readonly SmartGuardDbContext _db;
        private readonly ITokenService _tokenService;

        public AdminController(SmartGuardDbContext db, ITokenService tokenService)
        {
            _db = db;
            _tokenService = tokenService;
        }

        private Guid CurrentUserId =>
            Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub"), out var id)
                ? id
                : Guid.Empty;

        private static string NormalizeRole(string? rawRole)
        {
            if (string.IsNullOrWhiteSpace(rawRole)) return "Owner";
            if (rawRole.Equals("Admin", StringComparison.OrdinalIgnoreCase)) return "Admin";
            if (rawRole.Equals("Member", StringComparison.OrdinalIgnoreCase)) return "Member";
            return "Owner";
        }

        [HttpGet("stats")]
        public async Task<IActionResult> GetDashboardStats()
        {
            var today = DateTime.UtcNow.Date;

            var totalUsers = await _db.Users.CountAsync();
            var totalDevices = await _db.Devices.CountAsync();
            var totalAlertsToday = await _db.AlertEvents.CountAsync(a => a.TriggeredAt >= today);
            var activeArmedDevices = await _db.Devices.CountAsync(d => d.IsArmed);

            return Ok(new AdminStatsDto(
                TotalUsers: totalUsers,
                TotalDevices: totalDevices,
                TotalAlertsToday: totalAlertsToday,
                ActiveArmedDevices: activeArmedDevices
            ));
        }

        [HttpGet("users")]
        public async Task<IActionResult> GetUsers()
        {
            var users = await _db.Users
                .OrderByDescending(u => u.CreatedAt)
                .Select(u => new UserProfileDto(
                    u.Id,
                    u.Email,
                    u.Username,
                    u.Role,
                    u.IsLocked,
                    u.CreatedAt
                ))
                .ToListAsync();

            return Ok(users);
        }

        [HttpPatch("users/{id:guid}/status")]
        public async Task<IActionResult> UpdateUserStatus(Guid id, [FromBody] UpdateUserStatusDto dto)
        {
            var user = await _db.Users.FindAsync(id);
            if (user == null) return NotFound(new { message = "Không tìm thấy người dùng." });

            if (!string.IsNullOrWhiteSpace(dto.Role))
            {
                user.Role = NormalizeRole(dto.Role);
            }

            if (dto.IsLocked.HasValue)
            {
                if (dto.IsLocked.Value && user.Id == CurrentUserId)
                    return BadRequest(new { message = "Bạn không thể tự khóa tài khoản quản trị đang đăng nhập." });
                user.IsLocked = dto.IsLocked.Value;
            }

            await _db.SaveChangesAsync();

            return Ok(new { message = "Cập nhật trạng thái người dùng thành công.", userId = user.Id, isLocked = user.IsLocked, role = user.Role });
        }

        [HttpPost("users")]
        public async Task<IActionResult> CreateUser([FromBody] CreateUserAdminDto dto)
        {
            var normalizedEmail = (dto.Email ?? string.Empty).Trim().ToLowerInvariant();
            var normalizedUsername = (dto.Username ?? string.Empty).Trim().ToLowerInvariant();

            if (string.IsNullOrWhiteSpace(normalizedEmail) || string.IsNullOrWhiteSpace(normalizedUsername))
                return BadRequest(new { message = "Email và tên đăng nhập không được để trống." });

            if (await _db.Users.AnyAsync(u => u.Email == normalizedEmail))
                return BadRequest(new { message = "Email này đã được sử dụng." });

            if (await _db.Users.AnyAsync(u => u.Username == normalizedUsername))
                return BadRequest(new { message = "Tên đăng nhập này đã tồn tại." });

            var role = NormalizeRole(dto.Role);

            var user = new User
            {
                Email = normalizedEmail,
                Username = normalizedUsername,
                PasswordHash = _tokenService.HashPassword(dto.Password),
                Role = role,
                EmailVerified = true,
                CreatedAt = DateTime.UtcNow
            };

            _db.Users.Add(user);
            await _db.SaveChangesAsync();

            return Ok(new UserProfileDto(
                user.Id,
                user.Email,
                user.Username,
                user.Role,
                user.IsLocked,
                user.CreatedAt
            ));
        }

        [HttpPut("users/{id:guid}")]
        public async Task<IActionResult> UpdateUser(Guid id, [FromBody] UpdateUserAdminDto dto)
        {
            var user = await _db.Users.FindAsync(id);
            if (user == null) return NotFound(new { message = "Không tìm thấy người dùng." });

            if (!string.IsNullOrWhiteSpace(dto.Email))
            {
                var normalizedEmail = dto.Email.Trim().ToLowerInvariant();
                if (await _db.Users.AnyAsync(u => u.Email == normalizedEmail && u.Id != id))
                    return BadRequest(new { message = "Email này đã được sử dụng bởi tài khoản khác." });
                user.Email = normalizedEmail;
            }

            if (!string.IsNullOrWhiteSpace(dto.Username))
            {
                var normalizedUsername = dto.Username.Trim().ToLowerInvariant();
                if (await _db.Users.AnyAsync(u => u.Username == normalizedUsername && u.Id != id))
                    return BadRequest(new { message = "Tên đăng nhập này đã được sử dụng bởi tài khoản khác." });
                user.Username = normalizedUsername;
            }

            if (!string.IsNullOrWhiteSpace(dto.Role))
            {
                user.Role = NormalizeRole(dto.Role);
            }

            if (!string.IsNullOrWhiteSpace(dto.Password))
            {
                user.PasswordHash = _tokenService.HashPassword(dto.Password);
            }

            if (dto.IsLocked.HasValue)
            {
                if (dto.IsLocked.Value && user.Id == CurrentUserId)
                    return BadRequest(new { message = "Bạn không thể tự khóa tài khoản quản trị đang đăng nhập." });
                user.IsLocked = dto.IsLocked.Value;
            }

            await _db.SaveChangesAsync();

            return Ok(new UserProfileDto(
                user.Id,
                user.Email,
                user.Username,
                user.Role,
                user.IsLocked,
                user.CreatedAt
            ));
        }

        [HttpDelete("users/{id:guid}")]
        public async Task<IActionResult> DeleteUser(Guid id)
        {
            if (id == CurrentUserId)
                return BadRequest(new { message = "Bạn không thể tự xóa tài khoản quản trị đang đăng nhập." });

            var user = await _db.Users.FindAsync(id);
            if (user == null) return NotFound(new { message = "Không tìm thấy người dùng." });

            // Dọn dẹp các bảng liên kết có DeleteBehavior.Restrict hoặc không có FK trực tiếp để tránh lỗi SQL FK constraint
            var memberLinks = await _db.MemberAccesses
                .Where(m => m.MemberUserId == id || m.OwnerId == id)
                .ToListAsync();
            if (memberLinks.Count > 0) _db.MemberAccesses.RemoveRange(memberLinks);

            var profiles = await _db.AdaptiveProfiles
                .Where(p => p.UserId == id)
                .ToListAsync();
            if (profiles.Count > 0) _db.AdaptiveProfiles.RemoveRange(profiles);

            var otps = await _db.OtpChallenges
                .Where(o => o.UserId == id)
                .ToListAsync();
            if (otps.Count > 0) _db.OtpChallenges.RemoveRange(otps);

            var userDeviceIds = await _db.Devices
                .Where(d => d.OwnerId == id)
                .Select(d => d.Id)
                .ToListAsync();
            if (userDeviceIds.Count > 0)
            {
                var evidences = await _db.EvidenceImages
                    .Where(e => userDeviceIds.Contains(e.DeviceId))
                    .ToListAsync();
                if (evidences.Count > 0) _db.EvidenceImages.RemoveRange(evidences);
            }

            _db.Users.Remove(user);
            await _db.SaveChangesAsync();

            return Ok(new { message = "Đã xóa tài khoản người dùng thành công.", userId = id });
        }

        [HttpGet("system")]
        public IActionResult GetSystemInfo()
        {
            using var proc = Process.GetCurrentProcess();

            return Ok(new
            {
                serverTime = DateTime.UtcNow,
                osVersion = Environment.OSVersion.ToString(),
                machineName = Environment.MachineName,
                dotnetVersion = Environment.Version.ToString(),
                workingSetMemoryMb = Math.Round(proc.WorkingSet64 / (1024.0 * 1024.0), 2),
                threads = proc.Threads.Count,
                uptimeSeconds = (DateTime.UtcNow - proc.StartTime.ToUniversalTime()).TotalSeconds
            });
        }
    }
}
