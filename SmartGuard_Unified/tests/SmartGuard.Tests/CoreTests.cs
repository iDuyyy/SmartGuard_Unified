using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using SmartGuard.API.Controllers;
using SmartGuard.API.Data;
using SmartGuard.API.DTOs;
using SmartGuard.API.Models;
using SmartGuard.API.Services.Discord;
using SmartGuard.API.Services.Email;
using SmartGuard.API.Services.Security;
using Xunit;

namespace SmartGuard.Tests
{
    public class CoreTests
    {
        private readonly TokenService _tokenService;

        public CoreTests()
        {
            var options = Options.Create(new TokenOptions
            {
                Key = "Test_Secret_Key_At_Least_32_Bytes_Long_2026!",
                Issuer = "TestIssuer",
                Audience = "TestAudience",
                ExpirationHours = 2
            });
            _tokenService = new TokenService(options);
        }

        [Fact]
        public void Test_Password_Hashing_And_Verification()
        {
            const string plainPassword = "SecurePassword123@";
            var hash = _tokenService.HashPassword(plainPassword);

            Assert.NotNull(hash);
            Assert.NotEqual(plainPassword, hash);
            Assert.True(_tokenService.VerifyPassword(plainPassword, hash));
            Assert.False(_tokenService.VerifyPassword("WrongPassword!", hash));
        }

        [Fact]
        public void Test_Jwt_Token_Generation_Contains_Required_Claims()
        {
            var user = new User
            {
                Id = Guid.NewGuid(),
                Email = "testuser@example.com",
                Username = "testuser",
                Role = "Owner"
            };

            var tokenString = _tokenService.GenerateToken(user);
            Assert.False(string.IsNullOrWhiteSpace(tokenString));

            var handler = new JwtSecurityTokenHandler();
            var jwt = handler.ReadJwtToken(tokenString);

            Assert.Equal("TestIssuer", jwt.Issuer);
            Assert.Equal("testuser@example.com", jwt.Claims.First(c => c.Type == "email" || c.Type == ClaimTypes.Email).Value);
            Assert.Equal("Owner", jwt.Claims.First(c => c.Type == "role" || c.Type == ClaimTypes.Role).Value);
        }

        private SmartGuardDbContext CreateInMemoryDb()
        {
            var dbOptions = new DbContextOptionsBuilder<SmartGuardDbContext>()
                .UseInMemoryDatabase(databaseName: Guid.NewGuid().ToString())
                .Options;
            return new SmartGuardDbContext(dbOptions);
        }

        [Fact]
        public async Task Test_EndToEnd_Auth_Device_And_Alert_Flow()
        {
            using var db = CreateInMemoryDb();
            var mockEmail = new MockEmailService();
            var authController = new AuthController(db, _tokenService, mockEmail, NullLogger<AuthController>.Instance);

            // 1. Đăng ký tài khoản
            var registerRes = await authController.Register(new RegisterDto(
                Email: "homeowner@smartguard.com",
                Username: "homeowner",
                Password: "Password123@",
                Role: "Owner"
            )) as OkObjectResult;

            Assert.NotNull(registerRes);
            Assert.Equal(200, registerRes.StatusCode);

            // 2. Đăng nhập tạo Challenge 2FA
            var loginRes = await authController.Login(new LoginDto(
                Identifier: "homeowner@smartguard.com",
                Password: "Password123@"
            )) as OkObjectResult;

            Assert.NotNull(loginRes);
            var challenge = await db.OtpChallenges.FirstAsync();
            Assert.NotNull(challenge);
            Assert.Equal("Login", challenge.Purpose);

            // 3. Xác minh OTP (với mã từ mock email)
            var verifyRes = await authController.VerifyOtp(new VerifyOtpDto(
                ChallengeId: challenge.Id,
                Code: mockEmail.LastSentOtp!
            )) as OkObjectResult;

            Assert.NotNull(verifyRes);
            var authResponse = verifyRes.Value as AuthResponseDto;
            Assert.NotNull(authResponse);
            Assert.False(string.IsNullOrEmpty(authResponse.Token));

            // 4. Tạo thiết bị và kích hoạt canh gác
            var user = await db.Users.FirstAsync();
            var devicesController = new DevicesController(db, NullLogger<DevicesController>.Instance);
            devicesController.ControllerContext = CreateControllerContext(user);

            var createDevRes = await devicesController.CreateDevice(new CreateDeviceDto(
                Name: "Camera Cổng Trước",
                Description: "Android Camera đặt tại cổng trước",
                ZoneId: null
            )) as CreatedAtActionResult;

            Assert.NotNull(createDevRes);
            var deviceDto = createDevRes.Value as DeviceResponseDto;
            Assert.NotNull(deviceDto);
            Assert.True(deviceDto.IsArmed);

            // 5. Thử tắt / bật cảnh giác (Arm/Disarm)
            var toggleRes = await devicesController.ToggleArm(deviceDto.Id) as OkObjectResult;
            Assert.NotNull(toggleRes);
            var updatedDevice = await db.Devices.FindAsync(deviceDto.Id);
            Assert.False(updatedDevice!.IsArmed); // Đã chuyển sang false

            // Bật lại cảnh giác
            await devicesController.ToggleArm(deviceDto.Id);
            Assert.True(updatedDevice.IsArmed);

            // 6. Phát động cảnh báo an ninh (Trigger Alert)
            var mockDiscord = new MockDiscordService();
            var ruleEngine = new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance);
            var alertsController = new AlertsController(db, mockDiscord, ruleEngine, new MockWebHostEnv(), NullLogger<AlertsController>.Instance);
            alertsController.ControllerContext = CreateControllerContext(user);

            var triggerRes = await alertsController.TriggerAlert(new TriggerAlertDto(
                DeviceId: deviceDto.Id,
                TriggerReason: "NGUOI_LA",
                TriggerScore: 0.95,
                Severity: "Critical"
            )) as OkObjectResult;

            Assert.NotNull(triggerRes);
            var alert = await db.AlertEvents.FirstAsync();
            Assert.Equal("NGUOI_LA", alert.TriggerReason);
            Assert.Equal("Triggered", alert.Status);
            Assert.NotNull(alert.AdaptiveReason);

            // 7. Xác nhận cảnh báo an toàn
            var ackRes = await alertsController.AcknowledgeAlert(alert.Id, new AcknowledgeAlertDto("Confirmed")) as OkObjectResult;
            Assert.NotNull(ackRes);
            Assert.Equal("Confirmed", alert.Status);
            Assert.NotNull(alert.AcknowledgedAt);
        }

        [Fact]
        public async Task Test_Adaptive_Home_Mode_Suppresses_LivingRoom_Motion()
        {
            using var db = CreateInMemoryDb();
            var owner = new User { Email = "owner@test.com", Username = "owner", Role = "Owner" };
            db.Users.Add(owner);

            var livingRoomZone = new Zone { OwnerId = owner.Id, Name = "Phòng khách" };
            var gateZone = new Zone { OwnerId = owner.Id, Name = "Cổng trước" };
            db.Zones.AddRange(livingRoomZone, gateZone);

            var camLiving = new GuardDevice { OwnerId = owner.Id, ZoneId = livingRoomZone.Id, Name = "Cam Phòng Khách", IsArmed = true };
            var camGate = new GuardDevice { OwnerId = owner.Id, ZoneId = gateZone.Id, Name = "Cam Cổng", IsArmed = true };
            db.Devices.AddRange(camLiving, camGate);
            await db.SaveChangesAsync();

            var ruleEngine = new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance);
            await ruleEngine.InitializeDefaultProfilesForUserAsync(owner.Id);

            // Chế độ mặc định là "Ở nhà" (Home)
            // 1. Chuyển động ở Phòng khách -> Bị ngăn chặn (Suppressed) vì đây là khu vực sinh hoạt
            var evalLiving = await ruleEngine.EvaluateAlertAsync(camLiving, "CHUYEN_DONG", 1.0, "Warning");
            Assert.False(evalLiving.ShouldTriggerAlert);
            Assert.NotNull(evalLiving.SuppressionReason);
            Assert.Contains("Phòng khách", evalLiving.SuppressionReason);

            // 2. Chuyển động ở Cổng trước -> Được kích hoạt (Triggered) và có diễn giải nguồn gốc
            var evalGate = await ruleEngine.EvaluateAlertAsync(camGate, "CHUYEN_DONG", 1.0, "Warning");
            Assert.True(evalGate.ShouldTriggerAlert);
            Assert.Null(evalGate.SuppressionReason);
            Assert.Contains("Ở nhà", evalGate.ReasonExplanation);
            Assert.Contains("Cổng trước", evalGate.ReasonExplanation);
        }

        [Fact]
        public async Task Test_Adaptive_Snooze_Temporarily_Suppresses_Alerts()
        {
            using var db = CreateInMemoryDb();
            var owner = new User { Email = "owner2@test.com", Username = "owner2", Role = "Owner" };
            db.Users.Add(owner);

            var cam = new GuardDevice { OwnerId = owner.Id, Name = "Cam Sân", IsArmed = true };
            db.Devices.Add(cam);

            var profile = new AdaptiveProfile
            {
                UserId = owner.Id,
                ModeName = "Home",
                DisplayName = "Ở nhà",
                IsActive = true,
                SnoozeUntil = DateTime.UtcNow.AddMinutes(30) // Tạm dừng 30 phút
            };
            db.AdaptiveProfiles.Add(profile);
            await db.SaveChangesAsync();

            var ruleEngine = new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance);
            var eval = await ruleEngine.EvaluateAlertAsync(cam, "RUNG_LAC", 15.0, "Critical");

            Assert.False(eval.ShouldTriggerAlert);
            Assert.NotNull(eval.SuppressionReason);
            Assert.Contains("tạm dừng", eval.SuppressionReason);
        }

        [Fact]
        public async Task Test_Adaptive_Night_Mode_Applies_High_Sensitivity()
        {
            using var db = CreateInMemoryDb();
            var owner = new User { Email = "owner3@test.com", Username = "owner3", Role = "Owner" };
            db.Users.Add(owner);

            var zone = new Zone { OwnerId = owner.Id, Name = "Hàng rào" };
            db.Zones.Add(zone);

            var cam = new GuardDevice { OwnerId = owner.Id, ZoneId = zone.Id, Name = "Cam Hàng Rào", IsArmed = true };
            db.Devices.Add(cam);

            var nightProfile = new AdaptiveProfile
            {
                UserId = owner.Id,
                ModeName = "Night",
                DisplayName = "Ban đêm",
                IsActive = true,
                ZoneRules = new List<AdaptiveZoneRule>
                {
                    new()
                    {
                        ZoneId = zone.Id,
                        EnableMonitoring = true,
                        EnableAlarmSound = true,
                        EnableDiscordNotification = true,
                        CustomSensitivity = 1.5
                    }
                }
            };
            db.AdaptiveProfiles.Add(nightProfile);
            await db.SaveChangesAsync();

            var ruleEngine = new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance);
            var eval = await ruleEngine.EvaluateAlertAsync(cam, "NGUOI_LA", 0.9, "Critical");

            Assert.True(eval.ShouldTriggerAlert);
            Assert.True(eval.EnableAlarmSound);
            Assert.True(eval.EnableDiscordNotification);
            Assert.Contains("Ban đêm", eval.ReasonExplanation);
            Assert.Contains("x1.5", eval.ReasonExplanation);
        }

        [Fact]
        public async Task Test_Scenario_User_Returns_Home_Transitions_From_Away_To_Home()
        {
            using var db = CreateInMemoryDb();
            var owner = new User { Email = "user_scenario1@test.com", Username = "user_sc1", Role = "Owner" };
            db.Users.Add(owner);

            var livingZone = new Zone { OwnerId = owner.Id, Name = "Phòng khách" };
            var gateZone = new Zone { OwnerId = owner.Id, Name = "Cổng chính" };
            db.Zones.AddRange(livingZone, gateZone);

            var camLiving = new GuardDevice { OwnerId = owner.Id, ZoneId = livingZone.Id, Name = "Cam Phòng Khách", IsArmed = true };
            var camGate = new GuardDevice { OwnerId = owner.Id, ZoneId = gateZone.Id, Name = "Cam Cổng", IsArmed = true };
            db.Devices.AddRange(camLiving, camGate);
            await db.SaveChangesAsync();

            var ruleEngine = new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance);
            await ruleEngine.InitializeDefaultProfilesForUserAsync(owner.Id);

            var controller = new AdaptiveSecurityController(db, ruleEngine, NullLogger<AdaptiveSecurityController>.Instance)
            {
                ControllerContext = CreateControllerContext(owner)
            };

            // 1. Kích hoạt chế độ Vắng nhà (Away)
            var awayProfile = await db.AdaptiveProfiles.FirstAsync(p => p.UserId == owner.Id && p.ModeName == "Away");
            var actAway = await controller.ActivateProfile(awayProfile.Id);
            Assert.IsType<OkObjectResult>(actAway);

            // Ở chế độ Away: Cả phòng khách lẫn cổng đều kích hoạt cảnh báo
            var evalAwayLiving = await ruleEngine.EvaluateAlertAsync(camLiving, "CHUYEN_DONG", 1.0, "Warning");
            var evalAwayGate = await ruleEngine.EvaluateAlertAsync(camGate, "CHUYEN_DONG", 1.0, "Warning");
            Assert.True(evalAwayLiving.ShouldTriggerAlert);
            Assert.True(evalAwayGate.ShouldTriggerAlert);

            // 2. Người dùng về nhà: Chuyển sang chế độ Ở nhà (Home)
            var homeProfile = await db.AdaptiveProfiles.FirstAsync(p => p.UserId == owner.Id && p.ModeName == "Home");
            var actHome = await controller.ActivateProfile(homeProfile.Id);
            Assert.IsType<OkObjectResult>(actHome);

            // Kiểm tra sau khi chuyển sang Home:
            // - Phòng khách (khu vực sinh hoạt): Tự động giảm bớt / suppress cảnh báo
            var evalHomeLiving = await ruleEngine.EvaluateAlertAsync(camLiving, "CHUYEN_DONG", 1.0, "Warning");
            Assert.False(evalHomeLiving.ShouldTriggerAlert);
            Assert.Contains("Phòng khách", evalHomeLiving.SuppressionReason);

            // - Cổng chính: Vẫn canh gác nghiêm ngặt và kích hoạt cảnh báo
            var evalHomeGate = await ruleEngine.EvaluateAlertAsync(camGate, "CHUYEN_DONG", 1.0, "Warning");
            Assert.True(evalHomeGate.ShouldTriggerAlert);
            Assert.Contains("Ở nhà", evalHomeGate.ReasonExplanation);
        }

        [Fact]
        public async Task Test_Resilience_Invalid_Device_Returns_NotFound()
        {
            using var db = CreateInMemoryDb();
            var owner = new User { Email = "fault_tolerant@test.com", Username = "fault_tolerant", Role = "Owner" };
            db.Users.Add(owner);
            await db.SaveChangesAsync();

            var alertsController = new AlertsController(
                db, 
                new MockDiscordService(), 
                new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance), 
                new MockWebHostEnv(), 
                NullLogger<AlertsController>.Instance)
            {
                ControllerContext = CreateControllerContext(owner)
            };

            var nonExistentId = Guid.NewGuid();
            var result = await alertsController.TriggerAlert(new TriggerAlertDto(
                DeviceId: nonExistentId,
                TriggerReason: "CHUYEN_DONG",
                TriggerScore: 0.88,
                Severity: "Warning"
            ));

            Assert.IsType<NotFoundObjectResult>(result);
        }

        [Fact]
        public async Task Test_Resilience_Disarmed_Device_Skips_Trigger()
        {
            using var db = CreateInMemoryDb();
            var owner = new User { Email = "disarmed_test@test.com", Username = "disarmed_user", Role = "Owner" };
            db.Users.Add(owner);

            var cam = new GuardDevice { OwnerId = owner.Id, Name = "Cam Đã Tắt Canh Gác", IsArmed = false };
            db.Devices.Add(cam);
            await db.SaveChangesAsync();

            var alertsController = new AlertsController(
                db, 
                new MockDiscordService(), 
                new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance), 
                new MockWebHostEnv(), 
                NullLogger<AlertsController>.Instance)
            {
                ControllerContext = CreateControllerContext(owner)
            };

            var result = await alertsController.TriggerAlert(new TriggerAlertDto(
                DeviceId: cam.Id,
                TriggerReason: "RUNG_LAC",
                TriggerScore: 12.0,
                Severity: "Critical"
            )) as OkObjectResult;

            Assert.NotNull(result);
            Assert.Empty(db.AlertEvents); // Không tạo bản ghi cảnh báo rác
        }

        [Fact]
        public async Task Test_Connection_Auth_DevOtp_AlertTrigger_And_MemberShare_Contract()
        {
            using var db = CreateInMemoryDb();
            var mockEmail = new MockEmailService();
            var authController = new AuthController(db, _tokenService, mockEmail, NullLogger<AuthController>.Instance);

            // 1. Tạo tài khoản Admin local (.local) -> kiểm tra bypass SMTP và trả về devOtp cho Frontend
            var admin = new User
            {
                Email = "admin@smartguard.local",
                Username = "admin",
                PasswordHash = _tokenService.HashPassword("Admin@12345"),
                Role = "Admin"
            };
            var member = new User
            {
                Email = "member@smartguard.local",
                Username = "member1",
                PasswordHash = _tokenService.HashPassword("Member@12345"),
                Role = "Owner"
            };
            db.Users.AddRange(admin, member);
            await db.SaveChangesAsync();

            var loginRes = await authController.Login(new LoginDto("admin", "Admin@12345")) as OkObjectResult;
            Assert.NotNull(loginRes);
            var loginJson = System.Text.Json.JsonSerializer.Serialize(loginRes.Value);
            using var loginDoc = System.Text.Json.JsonDocument.Parse(loginJson);
            Assert.True(loginDoc.RootElement.TryGetProperty("devOtp", out var devOtpProp));
            var devOtp = devOtpProp.GetString();
            Assert.False(string.IsNullOrEmpty(devOtp));
            var challengeId = loginDoc.RootElement.GetProperty("challengeId").GetGuid();

            // 2. Verify OTP bằng devOtp
            var verifyRes = await authController.VerifyOtp(new VerifyOtpDto(challengeId, devOtp!)) as OkObjectResult;
            Assert.NotNull(verifyRes);
            var authDto = verifyRes.Value as AuthResponseDto;
            Assert.NotNull(authDto);
            Assert.Equal("Admin", authDto.Role);

            // 3. Tạo thiết bị và kiểm tra TriggerAlert trả về cả "id" và "alertId" cho Flutter
            var cam = new GuardDevice { OwnerId = admin.Id, Name = "Camera Cửa Chính", IsArmed = true };
            db.Devices.Add(cam);
            await db.SaveChangesAsync();

            var alertsController = new AlertsController(
                db,
                new MockDiscordService(),
                new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance),
                new MockWebHostEnv(),
                NullLogger<AlertsController>.Instance)
            {
                ControllerContext = CreateControllerContext(admin)
            };

            var triggerRes = await alertsController.TriggerAlert(new TriggerAlertDto(
                DeviceId: cam.Id,
                TriggerReason: "Kính vỡ (92%)",
                TriggerScore: 0.92,
                Severity: "Critical"
            )) as OkObjectResult;

            Assert.NotNull(triggerRes);
            var triggerJson = System.Text.Json.JsonSerializer.Serialize(triggerRes.Value);
            using var triggerDoc = System.Text.Json.JsonDocument.Parse(triggerJson);
            Assert.True(triggerDoc.RootElement.TryGetProperty("id", out var idProp));
            Assert.True(triggerDoc.RootElement.TryGetProperty("alertId", out var alertIdProp));
            Assert.Equal(idProp.GetGuid(), alertIdProp.GetGuid());

            // 4. Kiểm tra chia sẻ thiết bị cho thành viên (MembersController)
            var membersController = new MembersController(db)
            {
                ControllerContext = CreateControllerContext(admin)
            };

            var shareRes = await membersController.ShareDevice(new ShareAccessDto(
                MemberEmail: "member@smartguard.local",
                DeviceId: cam.Id,
                CanAcknowledge: true
            )) as OkObjectResult;
            Assert.NotNull(shareRes);

            var listRes = await membersController.GetSharedMembers() as OkObjectResult;
            Assert.NotNull(listRes);
            var sharedMembers = listRes.Value as IEnumerable<MemberAccessResponseDto>;
            Assert.NotNull(sharedMembers);
            var singleMember = Assert.Single(sharedMembers);
            Assert.Equal("member@smartguard.local", singleMember.MemberEmail);

            var revokeRes = await membersController.RevokeAccess(singleMember.Id) as OkObjectResult;
            Assert.NotNull(revokeRes);
            Assert.Empty(db.MemberAccesses);
        }

        [Fact]
        public async Task Test_SharedDevices_AllDevicesScope_ZoneBackfill_And_CascadeDelete()
        {
            using var db = CreateInMemoryDb();
            var owner1 = new User { Email = "owner1@test.com", Username = "owner1", Role = "Owner" };
            var owner2 = new User { Email = "owner2_isolated@test.com", Username = "owner2", Role = "Owner" };
            var member = new User { Email = "family@test.com", Username = "family", Role = "Member" };
            db.Users.AddRange(owner1, owner2, member);

            var cam1 = new GuardDevice { OwnerId = owner1.Id, Name = "Cam Sân Thượng Owner1", IsArmed = true };
            var cam2 = new GuardDevice { OwnerId = owner2.Id, Name = "Cam Bí Mật Owner2", IsArmed = true };
            db.Devices.AddRange(cam1, cam2);
            await db.SaveChangesAsync();

            // 1. Chia sẻ toàn bộ thiết bị của owner1 (DeviceId = null) cho member
            var membersCtrl = new MembersController(db) { ControllerContext = CreateControllerContext(owner1) };
            await membersCtrl.ShareDevice(new ShareAccessDto(member.Email, null, true));

            // 2. Member gọi GetDevices -> Chỉ thấy thiết bị của owner1, KHÔNG thấy thiết bị của owner2
            var devicesCtrlMember = new DevicesController(db, NullLogger<DevicesController>.Instance)
            {
                ControllerContext = CreateControllerContext(member)
            };
            var memberDevsRes = await devicesCtrlMember.GetDevices() as OkObjectResult;
            Assert.NotNull(memberDevsRes);
            var memberDevs = (memberDevsRes.Value as IEnumerable<DeviceResponseDto>)!.ToList();
            Assert.Single(memberDevs);
            Assert.Equal(cam1.Id, memberDevs[0].Id);

            // Member truy cập hoặc điều khiển cam2 của owner2 -> Phải bị chặn (NotFound để chống dò quét ID giữa các chủ nhà)
            var notFoundRes = await devicesCtrlMember.GetDevice(cam2.Id);
            Assert.IsType<NotFoundObjectResult>(notFoundRes);
            var notFoundToggleRes = await devicesCtrlMember.ToggleArm(cam2.Id);
            Assert.IsType<NotFoundObjectResult>(notFoundToggleRes);

            // 3. Kiểm tra tự động bổ sung quy tắc (ZoneRule Backfill) khi tạo Zone mới sau khi đã khởi tạo AdaptiveProfile
            var ruleEngine = new SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine(db, NullLogger<SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>.Instance);
            await ruleEngine.InitializeDefaultProfilesForUserAsync(owner1.Id);

            var newZone = new Zone { OwnerId = owner1.Id, Name = "Phòng ngủ tầng 2" };
            db.Zones.Add(newZone);
            await db.SaveChangesAsync();

            await ruleEngine.InitializeDefaultProfilesForUserAsync(owner1.Id);
            var homeProfile = await db.AdaptiveProfiles.Include(p => p.ZoneRules)
                .FirstAsync(p => p.UserId == owner1.Id && p.ModeName == "Home");
            var backfilledRule = Assert.Single(homeProfile.ZoneRules!, r => r.ZoneId == newZone.Id);
            Assert.False(backfilledRule.EnableMonitoring); // Phòng ngủ tự động tắt giám sát ở chế độ Ở nhà

            // 4. Kiểm tra xóa thiết bị có chứa ảnh bằng chứng (DeleteDevice) không bị lỗi khóa ngoại
            var alert = new AlertEvent { DeviceId = cam1.Id, TriggerReason = "NGUOI_LA", Severity = "Critical" };
            db.AlertEvents.Add(alert);
            db.EvidenceImages.Add(new EvidenceImage { DeviceId = cam1.Id, AlertEventId = alert.Id, FileName = "test.jpg", RelativeUrl = "/uploads/evidence/test.jpg" });
            await db.SaveChangesAsync();

            var devicesCtrlOwner = new DevicesController(db, NullLogger<DevicesController>.Instance)
            {
                ControllerContext = CreateControllerContext(owner1)
            };
            var delDevRes = await devicesCtrlOwner.DeleteDevice(cam1.Id);
            Assert.IsType<OkObjectResult>(delDevRes);
            Assert.Empty(db.EvidenceImages);
        }

        private static ControllerContext CreateControllerContext(User user)
        {
            var claims = new ClaimsPrincipal(new ClaimsIdentity(new[]
            {
                new Claim(ClaimTypes.NameIdentifier, user.Id.ToString()),
                new Claim(ClaimTypes.Name, user.Username),
                new Claim(ClaimTypes.Email, user.Email),
                new Claim(ClaimTypes.Role, user.Role),
            }, "TestAuth"));

            return new ControllerContext
            {
                HttpContext = new Microsoft.AspNetCore.Http.DefaultHttpContext { User = claims }
            };
        }
    }

    public class MockEmailService : IEmailService
    {
        public string? LastSentOtp { get; private set; }

        public Task<bool> SendOtpEmailAsync(string toEmail, string otpCode, string purpose)
        {
            LastSentOtp = otpCode;
            if (toEmail.EndsWith(".local", StringComparison.OrdinalIgnoreCase))
            {
                return Task.FromResult(false);
            }
            return Task.FromResult(true);
        }
    }

    public class MockDiscordService : IDiscordAlertService
    {
        public bool AlertSent { get; private set; }

        public Task SendAlertWithImageAsync(Guid alertId, string deviceName, string triggerReason, string severity, string? localImagePath, string? serverBaseUrl = null)
        {
            AlertSent = true;
            return Task.CompletedTask;
        }

        public Task UpdateAlertActionAsync(Guid alertId, string status, string responderName)
        {
            return Task.CompletedTask;
        }
    }

    public class MockWebHostEnv : Microsoft.AspNetCore.Hosting.IWebHostEnvironment
    {
        public string WebRootPath { get; set; } = AppContext.BaseDirectory;
        public Microsoft.Extensions.FileProviders.IFileProvider WebRootFileProvider { get; set; } = null!;
        public string ApplicationName { get; set; } = "SmartGuard.API";
        public Microsoft.Extensions.FileProviders.IFileProvider ContentRootFileProvider { get; set; } = null!;
        public string ContentRootPath { get; set; } = AppContext.BaseDirectory;
        public string EnvironmentName { get; set; } = "Development";
    }
}
