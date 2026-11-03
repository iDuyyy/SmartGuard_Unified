using System.Security.Claims;
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
    public class MembersController : ControllerBase
    {
        private readonly SmartGuardDbContext _db;

        public MembersController(SmartGuardDbContext db)
        {
            _db = db;
        }

        private Guid CurrentUserId =>
            Guid.TryParse(User.FindFirstValue(ClaimTypes.NameIdentifier) ?? User.FindFirstValue("sub"), out var id)
                ? id
                : Guid.Empty;

        [HttpGet]
        public async Task<IActionResult> GetSharedMembers()
        {
            var userId = CurrentUserId;
            if (userId == Guid.Empty) return Unauthorized();

            var list = await _db.MemberAccesses
                .Include(m => m.MemberUser)
                .Include(m => m.Device)
                .Where(m => m.OwnerId == userId)
                .Select(m => new MemberAccessResponseDto(
                    m.Id,
                    m.MemberUserId,
                    m.MemberUser != null ? m.MemberUser.Email : "",
                    m.MemberUser != null ? m.MemberUser.Username : "",
                    m.DeviceId,
                    m.Device != null ? m.Device.Name : "Tất cả thiết bị",
                    m.CanAcknowledge,
                    m.CreatedAt
                ))
                .ToListAsync();

            return Ok(list);
        }

        [HttpPost("share")]
        public async Task<IActionResult> ShareDevice([FromBody] ShareAccessDto dto)
        {
            var userId = CurrentUserId;
            if (userId == Guid.Empty) return Unauthorized();

            var targetEmail = (dto.MemberEmail ?? string.Empty).Trim().ToLowerInvariant();
            if (string.IsNullOrWhiteSpace(targetEmail))
                return BadRequest(new { message = "Email thành viên không được để trống." });

            var targetUser = await _db.Users.FirstOrDefaultAsync(u => u.Email == targetEmail || u.Username == targetEmail);
            if (targetUser == null)
                return NotFound(new { message = "Không tìm thấy người dùng có email này để chia sẻ." });

            if (targetUser.Id == userId)
                return BadRequest(new { message = "Bạn không thể tự chia sẻ thiết bị cho chính mình." });

            if (dto.DeviceId.HasValue)
            {
                var deviceExists = await _db.Devices.AnyAsync(d => d.Id == dto.DeviceId.Value && d.OwnerId == userId);
                if (!deviceExists) return BadRequest(new { message = "Thiết bị không tồn tại hoặc bạn không có quyền sở hữu." });
            }

            var alreadyShared = await _db.MemberAccesses.AnyAsync(m =>
                m.OwnerId == userId &&
                m.MemberUserId == targetUser.Id &&
                m.DeviceId == dto.DeviceId);

            if (alreadyShared)
                return BadRequest(new { message = "Quyền truy cập này đã được cấp trước đó." });

            var memberAccess = new MemberAccess
            {
                OwnerId = userId,
                MemberUserId = targetUser.Id,
                DeviceId = dto.DeviceId,
                CanAcknowledge = dto.CanAcknowledge
            };

            _db.MemberAccesses.Add(memberAccess);
            await _db.SaveChangesAsync();

            return Ok(new { message = $"Đã cấp quyền truy cập thành công cho {targetUser.Email}." });
        }

        [HttpDelete("{id:guid}")]
        public async Task<IActionResult> RevokeAccess(Guid id)
        {
            var userId = CurrentUserId;
            var access = await _db.MemberAccesses.FirstOrDefaultAsync(m => m.Id == id && (m.OwnerId == userId || User.IsInRole("Admin")));
            if (access == null) return NotFound(new { message = "Không tìm thấy quyền truy cập." });

            _db.MemberAccesses.Remove(access);
            await _db.SaveChangesAsync();

            return Ok(new { message = "Đã thu hồi quyền truy cập thành công." });
        }
    }
}
