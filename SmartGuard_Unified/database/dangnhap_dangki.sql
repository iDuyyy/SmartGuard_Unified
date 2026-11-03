-- ==========================================================================================================
-- DỰ ÁN: SMARTGUARD UNIFIED — CAPYBARA SECURITY EDITION (HỆ THỐNG GIÁM SÁT AN NINH THÔNG MINH)
-- TỆP SCRIPT: database/smartguard_db_script.sql
-- TƯƠNG THÍCH: Somee Cloud MSSQL Web Console, SQL Server 2017/2019/2022, SQL Express, LocalDB
-- ĐẶC ĐIỂM KỸ THUẬT:
--   1. KHÔNG sử dụng lệnh 'GO' (vốn gây lỗi "Incorrect syntax near 'GO'" trên Somee Web Query Console).
--   2. Đã xử lý triệt để lỗi "Msg 1785: Multiple Cascade Paths" của SQL Server giữa Users -> Zones -> Devices.
--   3. Idempotent 100% (Chạy lại nhiều lần an toàn: tự tạo bảng nếu thiếu, tự cập nhật tài khoản mặc định).
--   4. Bao gồm đầy đủ 10 bảng (9 bảng nghiệp vụ + 1 bảng EF Migrations) và dữ liệu mẫu toàn hệ thống.
-- ==========================================================================================================

SET NOCOUNT ON;

-- ==========================================================================================================
-- PHẦN 1: KHỞI TẠO CẤU TRÚC BẢNG DỮ LIỆU (DDL - DATA DEFINITION LANGUAGE)
-- ==========================================================================================================

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 0: [__EFMigrationsHistory] — Quản lý lịch sử phiên bản Entity Framework Core (.NET 8)
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[__EFMigrationsHistory]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[__EFMigrationsHistory] (
        [MigrationId]    NVARCHAR(150) NOT NULL, -- Mã định danh bản Migration (VD: 20261102173009_InitialCreate)
        [ProductVersion] NVARCHAR(32)  NOT NULL, -- Phiên bản EF Core (VD: 8.0.10)
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY CLUSTERED ([MigrationId] ASC)
    );
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 1: [Users] — Quản lý tài khoản người dùng & Phân quyền RBAC (Admin, Owner, Member)
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[Users]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[Users] (
        [Id]            UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_Users_Id] DEFAULT (NEWID()),
        [Email]         NVARCHAR(100)    NOT NULL, -- Địa chỉ Email đăng nhập & nhận mã OTP 2FA (Unique)
        [Username]      NVARCHAR(50)     NOT NULL, -- Tên đăng nhập định danh (Unique, viết thường)
        [PasswordHash]  NVARCHAR(MAX)    NOT NULL, -- Chuỗi mật khẩu mã hóa một chiều BCrypt (WorkFactor 11)
        [Role]          NVARCHAR(20)     NOT NULL CONSTRAINT [DF_Users_Role] DEFAULT (N'Owner'), -- 'Admin' | 'Owner' | 'Member'
        [EmailVerified] BIT              NOT NULL CONSTRAINT [DF_Users_EmailVerified] DEFAULT (1), -- 1: Đã xác thực Email
        [IsLocked]      BIT              NOT NULL CONSTRAINT [DF_Users_IsLocked] DEFAULT (0),      -- 1: Bị khóa bởi Admin
        [CreatedAt]     DATETIME2        NOT NULL CONSTRAINT [DF_Users_CreatedAt] DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT [PK_Users] PRIMARY KEY CLUSTERED ([Id] ASC)
    );

    CREATE UNIQUE NONCLUSTERED INDEX [IX_Users_Email]    ON [dbo].[Users] ([Email] ASC);
    CREATE UNIQUE NONCLUSTERED INDEX [IX_Users_Username] ON [dbo].[Users] ([Username] ASC);
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 2: [OtpChallenges] — Quản lý phiên xác thực đa nhân tố 2FA OTP (6 chữ số)
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[OtpChallenges]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[OtpChallenges] (
        [Id]        UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_OtpChallenges_Id] DEFAULT (NEWID()),
        [UserId]    UNIQUEIDENTIFIER NOT NULL, -- ID người dùng yêu cầu mã OTP
        [Purpose]   NVARCHAR(30)     NOT NULL CONSTRAINT [DF_OtpChallenges_Purpose] DEFAULT (N'Login'), -- 'Login' | 'VerifyEmail'
        [CodeHash]  NVARCHAR(MAX)    NOT NULL, -- Mã OTP 6 số đã được băm bằng BCrypt (không lưu明 văn)
        [Attempts]  INT              NOT NULL CONSTRAINT [DF_OtpChallenges_Attempts] DEFAULT (0), -- Số lần nhập sai (tối đa 5 lần)
        [ExpiresAt] DATETIME2        NOT NULL, -- Thời điểm hết hạn (mặc định +5 phút từ lúc phát sinh)
        [UsedAt]    DATETIME2        NULL,     -- Thời điểm mã OTP đã được sử dụng thành công (chống Replay Attack)
        CONSTRAINT [PK_OtpChallenges] PRIMARY KEY CLUSTERED ([Id] ASC)
    );

    CREATE NONCLUSTERED INDEX [IX_OtpChallenges_UserId] ON [dbo].[OtpChallenges] ([UserId] ASC);
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 3: [Zones] — Phân vùng không gian an ninh (Cổng chính, Phòng khách, Sân trước, Ban công...)
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[Zones]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[Zones] (
        [Id]          UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_Zones_Id] DEFAULT (NEWID()),
        [OwnerId]     UNIQUEIDENTIFIER NOT NULL, -- Chủ sở hữu khu vực (FK -> Users.Id)
        [Name]        NVARCHAR(100)    NOT NULL, -- Tên khu vực (VD: Cổng chính, Phòng khách)
        [Description] NVARCHAR(255)    NOT NULL CONSTRAINT [DF_Zones_Description] DEFAULT (N''), -- Mô tả vị trí
        CONSTRAINT [PK_Zones] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_Zones_Users_OwnerId] FOREIGN KEY ([OwnerId])
            REFERENCES [dbo].[Users] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_Zones_OwnerId] ON [dbo].[Zones] ([OwnerId] ASC);
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 4: [Devices] — Thiết bị giám sát IoT / Camera điện thoại (GuardDevice)
-- Lưu ý: FK_Devices_Zones_ZoneId dùng ON DELETE NO ACTION để tránh lỗi Msg 1785 Multiple Cascade Paths
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[Devices]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[Devices] (
        [Id]              UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_Devices_Id] DEFAULT (NEWID()),
        [OwnerId]         UNIQUEIDENTIFIER NOT NULL, -- Chủ sở hữu thiết bị (FK -> Users.Id)
        [ZoneId]          UNIQUEIDENTIFIER NULL,     -- Phân vùng lắp đặt (FK -> Zones.Id, cho phép NULL)
        [Name]            NVARCHAR(100)    NOT NULL, -- Tên hiển thị thiết bị (VD: Camera Cổng Chính)
        [DeviceCode]      NVARCHAR(50)     NOT NULL, -- Mã ghép nối 8 ký tự duy nhất (VD: CAM-GATE-01, SG-8842A)
        [Description]     NVARCHAR(255)    NOT NULL CONSTRAINT [DF_Devices_Description] DEFAULT (N''),
        [IsArmed]         BIT              NOT NULL CONSTRAINT [DF_Devices_IsArmed] DEFAULT (1), -- 1: Đang bật canh gác
        [NoiseThreshold]  FLOAT            NOT NULL CONSTRAINT [DF_Devices_NoiseThreshold] DEFAULT (70.0), -- Ngưỡng âm thanh (dB)
        [MotionThreshold] FLOAT            NOT NULL CONSTRAINT [DF_Devices_MotionThreshold] DEFAULT (3.5), -- Ngưỡng gia tốc rung (m/s2)
        [RegisteredAt]    DATETIME2        NOT NULL CONSTRAINT [DF_Devices_RegisteredAt] DEFAULT (SYSUTCDATETIME()),
        [LastSeenAt]      DATETIME2        NOT NULL CONSTRAINT [DF_Devices_LastSeenAt] DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT [PK_Devices] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_Devices_Users_OwnerId] FOREIGN KEY ([OwnerId])
            REFERENCES [dbo].[Users] ([Id]) ON DELETE CASCADE,
        CONSTRAINT [FK_Devices_Zones_ZoneId] FOREIGN KEY ([ZoneId])
            REFERENCES [dbo].[Zones] ([Id]) ON DELETE NO ACTION
    );

    CREATE UNIQUE NONCLUSTERED INDEX [IX_Devices_DeviceCode] ON [dbo].[Devices] ([DeviceCode] ASC);
    CREATE NONCLUSTERED INDEX [IX_Devices_OwnerId]           ON [dbo].[Devices] ([OwnerId] ASC);
    CREATE NONCLUSTERED INDEX [IX_Devices_ZoneId]            ON [dbo].[Devices] ([ZoneId] ASC);
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 5: [MemberAccesses] — Phân quyền chia sẻ thiết bị cho thành viên gia đình (Member)
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[MemberAccesses]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[MemberAccesses] (
        [Id]             UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_MemberAccesses_Id] DEFAULT (NEWID()),
        [OwnerId]        UNIQUEIDENTIFIER NOT NULL, -- ID Chủ nhà cấp quyền
        [MemberUserId]   UNIQUEIDENTIFIER NOT NULL, -- ID Thành viên được cấp quyền (FK -> Users.Id)
        [DeviceId]       UNIQUEIDENTIFIER NULL,     -- NULL = Toàn quyền mọi thiết bị của Owner; Khác NULL = Chỉ 1 thiết bị
        [CanAcknowledge] BIT              NOT NULL CONSTRAINT [DF_MemberAccesses_CanAcknowledge] DEFAULT (1), -- Quyền tắt còi/xác nhận báo động
        [CreatedAt]      DATETIME2        NOT NULL CONSTRAINT [DF_MemberAccesses_CreatedAt] DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT [PK_MemberAccesses] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_MemberAccesses_Users_MemberUserId] FOREIGN KEY ([MemberUserId])
            REFERENCES [dbo].[Users] ([Id]) ON DELETE NO ACTION,
        CONSTRAINT [FK_MemberAccesses_Devices_DeviceId] FOREIGN KEY ([DeviceId])
            REFERENCES [dbo].[Devices] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_MemberAccesses_MemberUserId] ON [dbo].[MemberAccesses] ([MemberUserId] ASC);
    CREATE NONCLUSTERED INDEX [IX_MemberAccesses_DeviceId]     ON [dbo].[MemberAccesses] ([DeviceId] ASC);
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 6: [AlertEvents] — Nhật ký sự kiện báo động đa phương thức & Giải thích Adaptive AI
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[AlertEvents]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[AlertEvents] (
        [Id]               UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_AlertEvents_Id] DEFAULT (NEWID()),
        [DeviceId]         UNIQUEIDENTIFIER NOT NULL, -- Thiết bị phát sinh cảnh báo (FK -> Devices.Id)
        [TriggerReason]    NVARCHAR(50)     NOT NULL CONSTRAINT [DF_AlertEvents_TriggerReason] DEFAULT (N'CHUYEN_DONG'), -- RUNG_LAC | TIENG_DONG | NGUOI_LA | VO_KINH
        [TriggerScore]     FLOAT            NOT NULL CONSTRAINT [DF_AlertEvents_TriggerScore] DEFAULT (0.0), -- Điểm hợp nhất cảm biến (0.0 -> 1.0)
        [Severity]         NVARCHAR(20)     NOT NULL CONSTRAINT [DF_AlertEvents_Severity] DEFAULT (N'Warning'), -- 'Info' | 'Warning' | 'Critical'
        [TriggeredAt]      DATETIME2        NOT NULL CONSTRAINT [DF_AlertEvents_TriggeredAt] DEFAULT (SYSUTCDATETIME()),
        [ImageUrl]         NVARCHAR(MAX)    NULL,     -- Đường dẫn ảnh bằng chứng hiện trường
        [DiscordMessageId] NVARCHAR(MAX)    NULL,     -- ID tin nhắn gửi sang kênh Discord Bot
        [AcknowledgedBy]   UNIQUEIDENTIFIER NULL,     -- ID người dùng đã xác nhận/tắt báo động
        [AcknowledgedAt]   DATETIME2        NULL,     -- Thời điểm xác nhận xử lý
        [Status]           NVARCHAR(100)    NOT NULL CONSTRAINT [DF_AlertEvents_Status] DEFAULT (N'Triggered'), -- 'Triggered' | 'Dismissed' | 'Confirmed'
        [AdaptiveReason]   NVARCHAR(255)    NULL,     -- Chuỗi giải thích quyết định của Adaptive Rule Engine
        CONSTRAINT [PK_AlertEvents] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_AlertEvents_Devices_DeviceId] FOREIGN KEY ([DeviceId])
            REFERENCES [dbo].[Devices] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_AlertEvents_DeviceId]    ON [dbo].[AlertEvents] ([DeviceId] ASC);
    CREATE NONCLUSTERED INDEX [IX_AlertEvents_TriggeredAt] ON [dbo].[AlertEvents] ([TriggeredAt] DESC);
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 7: [EvidenceImages] — Kho lưu trữ ảnh chụp bằng chứng hiện trường từ Camera
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[EvidenceImages]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[EvidenceImages] (
        [Id]           UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_EvidenceImages_Id] DEFAULT (NEWID()),
        [AlertEventId] UNIQUEIDENTIFIER NULL,     -- Liên kết sự kiện báo động (FK -> AlertEvents.Id)
        [DeviceId]     UNIQUEIDENTIFIER NOT NULL, -- Thiết bị chụp ảnh
        [FileName]     NVARCHAR(255)    NOT NULL, -- Tên file vật lý (VD: alert_20261103.jpg)
        [RelativeUrl]  NVARCHAR(500)    NOT NULL, -- Đường dẫn tương đối phục vụ tĩnh (/evidence/...)
        [UploadedAt]   DATETIME2        NOT NULL CONSTRAINT [DF_EvidenceImages_UploadedAt] DEFAULT (SYSUTCDATETIME()),
        CONSTRAINT [PK_EvidenceImages] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_EvidenceImages_AlertEvents_AlertEventId] FOREIGN KEY ([AlertEventId])
            REFERENCES [dbo].[AlertEvents] ([Id]) ON DELETE NO ACTION
    );

    CREATE NONCLUSTERED INDEX [IX_EvidenceImages_AlertEventId] ON [dbo].[EvidenceImages] ([AlertEventId] ASC);
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 8: [AdaptiveProfiles] — Hồ sơ bảo mật thích ứng theo ngữ cảnh (Home, Away, Night, Custom)
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[AdaptiveProfiles]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[AdaptiveProfiles] (
        [Id]                   UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_AdaptiveProfiles_Id] DEFAULT (NEWID()),
        [UserId]               UNIQUEIDENTIFIER NOT NULL, -- Chủ sở hữu hồ sơ
        [ModeName]             NVARCHAR(50)     NOT NULL CONSTRAINT [DF_AdaptiveProfiles_ModeName] DEFAULT (N'Home'), -- 'Home' | 'Away' | 'Night' | 'Custom'
        [DisplayName]          NVARCHAR(100)    NOT NULL CONSTRAINT [DF_AdaptiveProfiles_DisplayName] DEFAULT (N'Ở nhà'),
        [Description]          NVARCHAR(255)    NOT NULL CONSTRAINT [DF_AdaptiveProfiles_Description] DEFAULT (N''),
        [IsActive]             BIT              NOT NULL CONSTRAINT [DF_AdaptiveProfiles_IsActive] DEFAULT (0), -- 1: Đang được kích hoạt
        [ActiveFrom]           NVARCHAR(5)      NOT NULL CONSTRAINT [DF_AdaptiveProfiles_ActiveFrom] DEFAULT (N'00:00'), -- Khung giờ bắt đầu (HH:mm)
        [ActiveTo]             NVARCHAR(5)      NOT NULL CONSTRAINT [DF_AdaptiveProfiles_ActiveTo] DEFAULT (N'23:59'),   -- Khung giờ kết thúc (HH:mm)
        [BehaviorOnDisconnect] NVARCHAR(50)     NOT NULL CONSTRAINT [DF_AdaptiveProfiles_Behavior] DEFAULT (N'AlertOffline'), -- 'AlertOffline' | 'MaintainState' | 'FailSecure'
        [SnoozeUntil]          DATETIME2        NULL,     -- Thời điểm kết thúc tạm dừng báo động (Snooze)
        CONSTRAINT [PK_AdaptiveProfiles] PRIMARY KEY CLUSTERED ([Id] ASC)
    );

    CREATE NONCLUSTERED INDEX [IX_AdaptiveProfiles_UserId] ON [dbo].[AdaptiveProfiles] ([UserId] ASC);
END;

-- ----------------------------------------------------------------------------------------------------------
-- BẢNG 9: [AdaptiveZoneRules] — Quy tắc lọc báo động & Hệ số nhạy cảm biến theo từng Phân vùng (Zone)
-- ----------------------------------------------------------------------------------------------------------
IF OBJECT_ID(N'[dbo].[AdaptiveZoneRules]', N'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[AdaptiveZoneRules] (
        [Id]                        UNIQUEIDENTIFIER NOT NULL CONSTRAINT [DF_AdaptiveZoneRules_Id] DEFAULT (NEWID()),
        [ProfileId]                 UNIQUEIDENTIFIER NOT NULL, -- Thuộc Hồ sơ bảo mật nào (FK -> AdaptiveProfiles.Id)
        [ZoneId]                    UNIQUEIDENTIFIER NOT NULL, -- Áp dụng cho Khu vực nào (FK -> Zones.Id)
        [EnableMonitoring]          BIT              NOT NULL CONSTRAINT [DF_AdaptiveZoneRules_Monitoring] DEFAULT (1), -- 0: Miễn trừ/Bỏ qua khu vực này
        [EnableAlarmSound]          BIT              NOT NULL CONSTRAINT [DF_AdaptiveZoneRules_AlarmSound] DEFAULT (1), -- 1: Cho phép hú còi tại chỗ
        [EnableDiscordNotification] BIT              NOT NULL CONSTRAINT [DF_AdaptiveZoneRules_Discord] DEFAULT (1),    -- 1: Cho phép bắn cảnh báo Discord
        [CustomSensitivity]         FLOAT            NOT NULL CONSTRAINT [DF_AdaptiveZoneRules_Sensitivity] DEFAULT (1.0), -- Hệ số nhân độ nhạy (0.5 -> 2.0)
        CONSTRAINT [PK_AdaptiveZoneRules] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_AdaptiveZoneRules_AdaptiveProfiles_ProfileId] FOREIGN KEY ([ProfileId])
            REFERENCES [dbo].[AdaptiveProfiles] ([Id]) ON DELETE CASCADE,
        CONSTRAINT [FK_AdaptiveZoneRules_Zones_ZoneId] FOREIGN KEY ([ZoneId])
            REFERENCES [dbo].[Zones] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_AdaptiveZoneRules_ProfileId] ON [dbo].[AdaptiveZoneRules] ([ProfileId] ASC);
    CREATE NONCLUSTERED INDEX [IX_AdaptiveZoneRules_ZoneId]    ON [dbo].[AdaptiveZoneRules] ([ZoneId] ASC);
END;


-- ==========================================================================================================
-- PHẦN 2: NẠP DỮ LIỆU MÃ KHỞI TẠO HỆ THỐNG (DML - SEED ACCOUNTS, CODES, ZONES, DEVICES, PROFILES)
-- ==========================================================================================================

-- 1. Đồng bộ lịch sử Migration của Entity Framework Core
IF NOT EXISTS (SELECT 1 FROM [dbo].[__EFMigrationsHistory] WHERE [MigrationId] = N'20261102173009_InitialCreate')
BEGIN
    INSERT INTO [dbo].[__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261102173009_InitialCreate', N'8.0.10');
END;

-- 2. Khởi tạo / Đặt lại mật khẩu chuẩn cho 3 Tài khoản Mặc định (Admin, Owner, Member)
DECLARE @AdminId  UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
DECLARE @OwnerId  UNIQUEIDENTIFIER = '22222222-2222-2222-2222-222222222222';
DECLARE @MemberId UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';

-- Mã băm BCrypt (WorkFactor 11) tương thích 100% với BCrypt.Net-Next trong TokenService.cs:
--   'Admin123@'    -> $2a$11$.ZdJU8D..qtBjLWlzMQ7leIOR97mFIEiAdTpA6D.3MvaL6wfPHtqu
--   'Password123@' -> $2a$11$7qn12U5aN5Mo7H.MFDjlNu4CfwPOM3p2kRx4Lflv3j.XnjI.6sVsy
DECLARE @AdminPassHash NVARCHAR(MAX) = N'$2a$11$.ZdJU8D..qtBjLWlzMQ7leIOR97mFIEiAdTpA6D.3MvaL6wfPHtqu';
DECLARE @UserPassHash  NVARCHAR(MAX) = N'$2a$11$7qn12U5aN5Mo7H.MFDjlNu4CfwPOM3p2kRx4Lflv3j.XnjI.6sVsy';

-- 2A. Tài khoản Quản trị viên: admin@smartguard.local / admin (Mật khẩu: Admin123@)
IF EXISTS (SELECT 1 FROM [dbo].[Users] WHERE [Email] = N'admin@smartguard.local' OR [Username] = N'admin')
BEGIN
    UPDATE [dbo].[Users]
    SET [Email]         = N'admin@smartguard.local',
        [Username]      = N'admin',
        [PasswordHash]  = @AdminPassHash,
        [Role]          = N'Admin',
        [EmailVerified] = 1,
        [IsLocked]      = 0
    WHERE [Email] = N'admin@smartguard.local' OR [Username] = N'admin';

    SELECT TOP 1 @AdminId = [Id] FROM [dbo].[Users] WHERE [Email] = N'admin@smartguard.local';
END
ELSE
BEGIN
    INSERT INTO [dbo].[Users] ([Id], [Email], [Username], [PasswordHash], [Role], [EmailVerified], [IsLocked], [CreatedAt])
    VALUES (@AdminId, N'admin@smartguard.local', N'admin', @AdminPassHash, N'Admin', 1, 0, SYSUTCDATETIME());
END;

-- 2B. Tài khoản Chủ nhà: user@smartguard.local / homeowner (Mật khẩu: Password123@)
IF EXISTS (SELECT 1 FROM [dbo].[Users] WHERE [Email] = N'user@smartguard.local' OR [Username] = N'homeowner')
BEGIN
    UPDATE [dbo].[Users]
    SET [Email]         = N'user@smartguard.local',
        [Username]      = N'homeowner',
        [PasswordHash]  = @UserPassHash,
        [Role]          = N'Owner',
        [EmailVerified] = 1,
        [IsLocked]      = 0
    WHERE [Email] = N'user@smartguard.local' OR [Username] = N'homeowner';

    SELECT TOP 1 @OwnerId = [Id] FROM [dbo].[Users] WHERE [Email] = N'user@smartguard.local';
END
ELSE
BEGIN
    INSERT INTO [dbo].[Users] ([Id], [Email], [Username], [PasswordHash], [Role], [EmailVerified], [IsLocked], [CreatedAt])
    VALUES (@OwnerId, N'user@smartguard.local', N'homeowner', @UserPassHash, N'Owner', 1, 0, SYSUTCDATETIME());
END;

-- 2C. Tài khoản Thành viên gia đình: member@smartguard.local / member1 (Mật khẩu: Password123@)
IF EXISTS (SELECT 1 FROM [dbo].[Users] WHERE [Email] = N'member@smartguard.local' OR [Username] = N'member1')
BEGIN
    UPDATE [dbo].[Users]
    SET [Email]         = N'member@smartguard.local',
        [Username]      = N'member1',
        [PasswordHash]  = @UserPassHash,
        [Role]          = N'Member',
        [EmailVerified] = 1,
        [IsLocked]      = 0
    WHERE [Email] = N'member@smartguard.local' OR [Username] = N'member1';

    SELECT TOP 1 @MemberId = [Id] FROM [dbo].[Users] WHERE [Email] = N'member@smartguard.local';
END
ELSE
BEGIN
    INSERT INTO [dbo].[Users] ([Id], [Email], [Username], [PasswordHash], [Role], [EmailVerified], [IsLocked], [CreatedAt])
    VALUES (@MemberId, N'member@smartguard.local', N'member1', @UserPassHash, N'Member', 1, 0, SYSUTCDATETIME());
END;

-- Xóa các phiên OTP cũ bị kẹt để người dùng đăng nhập mới mượt mà
DELETE FROM [dbo].[OtpChallenges] WHERE [ExpiresAt] < SYSUTCDATETIME();

-- 3. Khởi tạo 4 Phân vùng An ninh (Zones)
DECLARE @ZoneLivingId  UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444441';
DECLARE @ZoneGateId    UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444442';
DECLARE @ZoneYardId    UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444443';
DECLARE @ZoneBalconyId UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444444';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Phòng khách')
    INSERT INTO [dbo].[Zones] ([Id], [OwnerId], [Name], [Description])
    VALUES (@ZoneLivingId, @OwnerId, N'Phòng khách', N'Khu vực sinh hoạt chung tầng trệt');
ELSE
    SELECT TOP 1 @ZoneLivingId = [Id] FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Phòng khách';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Cổng chính')
    INSERT INTO [dbo].[Zones] ([Id], [OwnerId], [Name], [Description])
    VALUES (@ZoneGateId, @OwnerId, N'Cổng chính', N'Lối ra vào chính phía trước ngôi nhà');
ELSE
    SELECT TOP 1 @ZoneGateId = [Id] FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Cổng chính';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Sân trước')
    INSERT INTO [dbo].[Zones] ([Id], [OwnerId], [Name], [Description])
    VALUES (@ZoneYardId, @OwnerId, N'Sân trước', N'Khu vực để xe và sân vườn phía trước');
ELSE
    SELECT TOP 1 @ZoneYardId = [Id] FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Sân trước';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Ban công')
    INSERT INTO [dbo].[Zones] ([Id], [OwnerId], [Name], [Description])
    VALUES (@ZoneBalconyId, @OwnerId, N'Ban công', N'Ban công lầu 1 hướng ra mặt tiền');
ELSE
    SELECT TOP 1 @ZoneBalconyId = [Id] FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Ban công';

-- 4. Khởi tạo Thiết bị IoT & Mã ghép nối Thiết bị (DeviceCode)
DECLARE @DevCamGateId    UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555551';
DECLARE @DevSensLivingId UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555552';
DECLARE @DevDoorbellId   UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555553';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Devices] WHERE [DeviceCode] = N'CAM-GATE-01')
BEGIN
    INSERT INTO [dbo].[Devices] ([Id], [OwnerId], [ZoneId], [Name], [DeviceCode], [Description], [IsArmed], [NoiseThreshold], [MotionThreshold], [RegisteredAt], [LastSeenAt])
    VALUES (@DevCamGateId, @OwnerId, @ZoneGateId, N'Camera Cổng Chính', N'CAM-GATE-01', N'IP: 192.168.1.101 | Vị trí: Cửa chính | Loại: camera', 1, 70.0, 3.5, SYSUTCDATETIME(), SYSUTCDATETIME());
END
ELSE
    SELECT TOP 1 @DevCamGateId = [Id] FROM [dbo].[Devices] WHERE [DeviceCode] = N'CAM-GATE-01';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Devices] WHERE [DeviceCode] = N'SEN-LIV-01')
BEGIN
    INSERT INTO [dbo].[Devices] ([Id], [OwnerId], [ZoneId], [Name], [DeviceCode], [Description], [IsArmed], [NoiseThreshold], [MotionThreshold], [RegisteredAt], [LastSeenAt])
    VALUES (@DevSensLivingId, @OwnerId, @ZoneLivingId, N'Cảm biến Rung Phòng Khách', N'SEN-LIV-01', N'IP: 192.168.1.102 | Vị trí: Phòng khách | Loại: sensor', 1, 65.0, 2.8, SYSUTCDATETIME(), SYSUTCDATETIME());
END
ELSE
    SELECT TOP 1 @DevSensLivingId = [Id] FROM [dbo].[Devices] WHERE [DeviceCode] = N'SEN-LIV-01';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Devices] WHERE [DeviceCode] = N'BELL-GATE-01')
BEGIN
    INSERT INTO [dbo].[Devices] ([Id], [OwnerId], [ZoneId], [Name], [DeviceCode], [Description], [IsArmed], [NoiseThreshold], [MotionThreshold], [RegisteredAt], [LastSeenAt])
    VALUES (@DevDoorbellId, @OwnerId, @ZoneGateId, N'Chuông cửa Cổng Trước', N'BELL-GATE-01', N'IP: 192.168.1.103 | Vị trí: Cửa chính | Loại: doorbell', 1, 75.0, 4.0, SYSUTCDATETIME(), SYSUTCDATETIME());
END
ELSE
    SELECT TOP 1 @DevDoorbellId = [Id] FROM [dbo].[Devices] WHERE [DeviceCode] = N'BELL-GATE-01';

-- 5. Cấp quyền truy cập Camera cho Thành viên gia đình (MemberAccesses)
IF NOT EXISTS (SELECT 1 FROM [dbo].[MemberAccesses] WHERE [OwnerId] = @OwnerId AND [MemberUserId] = @MemberId)
BEGIN
    INSERT INTO [dbo].[MemberAccesses] ([Id], [OwnerId], [MemberUserId], [DeviceId], [CanAcknowledge], [CreatedAt])
    VALUES (NEWID(), @OwnerId, @MemberId, @DevCamGateId, 1, SYSUTCDATETIME());
END;

-- 6. Khởi tạo 3 Hồ sơ Bảo mật Thích ứng (Adaptive Profiles: Home, Away, Night) & Quy tắc Vùng
DECLARE @ProfileHomeId  UNIQUEIDENTIFIER = '66666666-6666-6666-6666-666666666661';
DECLARE @ProfileAwayId  UNIQUEIDENTIFIER = '66666666-6666-6666-6666-666666666662';
DECLARE @ProfileNightId UNIQUEIDENTIFIER = '66666666-6666-6666-6666-666666666663';

IF NOT EXISTS (SELECT 1 FROM [dbo].[AdaptiveProfiles] WHERE [UserId] = @OwnerId AND [ModeName] = N'Home')
BEGIN
    INSERT INTO [dbo].[AdaptiveProfiles] ([Id], [UserId], [ModeName], [DisplayName], [Description], [IsActive], [ActiveFrom], [ActiveTo], [BehaviorOnDisconnect])
    VALUES (@ProfileHomeId, @OwnerId, N'Home', N'Ở nhà', N'Giảm cảnh báo tại khu vực sinh hoạt trong nhà, tập trung bảo vệ lối vào/sân ngoài.', 1, N'00:00', N'23:59', N'AlertOffline');

    INSERT INTO [dbo].[AdaptiveZoneRules] ([Id], [ProfileId], [ZoneId], [EnableMonitoring], [EnableAlarmSound], [EnableDiscordNotification], [CustomSensitivity])
    VALUES
        (NEWID(), @ProfileHomeId, @ZoneLivingId, 0, 0, 1, 0.8),
        (NEWID(), @ProfileHomeId, @ZoneGateId,   1, 1, 1, 1.0);
END;

IF NOT EXISTS (SELECT 1 FROM [dbo].[AdaptiveProfiles] WHERE [UserId] = @OwnerId AND [ModeName] = N'Away')
BEGIN
    INSERT INTO [dbo].[AdaptiveProfiles] ([Id], [UserId], [ModeName], [DisplayName], [Description], [IsActive], [ActiveFrom], [ActiveTo], [BehaviorOnDisconnect])
    VALUES (@ProfileAwayId, @OwnerId, N'Away', N'Rời nhà', N'Tăng cường giám sát tối đa trên tất cả các khu vực, gửi thông báo khẩn cấp ngay lập tức.', 0, N'00:00', N'23:59', N'FailSecure');

    INSERT INTO [dbo].[AdaptiveZoneRules] ([Id], [ProfileId], [ZoneId], [EnableMonitoring], [EnableAlarmSound], [EnableDiscordNotification], [CustomSensitivity])
    VALUES
        (NEWID(), @ProfileAwayId, @ZoneLivingId, 1, 1, 1, 1.2),
        (NEWID(), @ProfileAwayId, @ZoneGateId,   1, 1, 1, 1.2);
END;

IF NOT EXISTS (SELECT 1 FROM [dbo].[AdaptiveProfiles] WHERE [UserId] = @OwnerId AND [ModeName] = N'Night')
BEGIN
    INSERT INTO [dbo].[AdaptiveProfiles] ([Id], [UserId], [ModeName], [DisplayName], [Description], [IsActive], [ActiveFrom], [ActiveTo], [BehaviorOnDisconnect])
    VALUES (@ProfileNightId, @OwnerId, N'Night', N'Ban đêm', N'Điều chỉnh vùng giám sát ban đêm với độ nhạy cao (x1.5), kích hoạt còi tại chỗ lập tức.', 0, N'22:00', N'06:00', N'FailSecure');

    INSERT INTO [dbo].[AdaptiveZoneRules] ([Id], [ProfileId], [ZoneId], [EnableMonitoring], [EnableAlarmSound], [EnableDiscordNotification], [CustomSensitivity])
    VALUES
        (NEWID(), @ProfileNightId, @ZoneLivingId, 1, 1, 1, 1.5),
        (NEWID(), @ProfileNightId, @ZoneGateId,   1, 1, 1, 1.5);
END;

-- 7. Khởi tạo Sự kiện Cảnh báo Mẫu (AlertEvents) & Ảnh Bằng chứng (EvidenceImages)
DECLARE @AlertEventId UNIQUEIDENTIFIER = '77777777-7777-7777-7777-777777777771';
IF NOT EXISTS (SELECT 1 FROM [dbo].[AlertEvents] WHERE [Id] = @AlertEventId)
BEGIN
    INSERT INTO [dbo].[AlertEvents] (
        [Id], [DeviceId], [TriggerReason], [TriggerScore], [Severity], [TriggeredAt],
        [ImageUrl], [DiscordMessageId], [AcknowledgedBy], [AcknowledgedAt], [Status], [AdaptiveReason]
    )
    VALUES (
        @AlertEventId,
        @DevCamGateId,
        N'Kính vỡ (92%)',
        0.92,
        N'Critical',
        DATEADD(MINUTE, -15, SYSUTCDATETIME()),
        N'/evidence/sample_alert.jpg',
        NULL,
        NULL,
        NULL,
        N'Triggered',
        N'Kích hoạt bởi Chế độ [Ở nhà] tại khu vực [Cổng chính] (AI phát hiện âm thanh vỡ kính)'
    );

    INSERT INTO [dbo].[EvidenceImages] ([Id], [AlertEventId], [DeviceId], [FileName], [RelativeUrl], [UploadedAt])
    VALUES (NEWID(), @AlertEventId, @DevCamGateId, N'sample_alert.jpg', N'/evidence/sample_alert.jpg', DATEADD(MINUTE, -15, SYSUTCDATETIME()));
END;

-- ==========================================================================================================
-- PHẦN 3: TRUY VẤN KIỂM TRA KẾT QUẢ SAU KHI CHẠY (HIỂN THỊ TRỰC TIẾP TRÊN SOMEE / SSMS)
-- ==========================================================================================================
SELECT
    t.name AS [TenBang_Table],
    p.rows AS [SoBanGhi_RowCount]
FROM sys.tables t
INNER JOIN sys.partitions p ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)
ORDER BY t.name;

SELECT
    [Id],
    [Username],
    [Email],
    [Role],
    [EmailVerified],
    [IsLocked],
    [CreatedAt]
FROM [dbo].[Users]
ORDER BY [Role], [Username];
