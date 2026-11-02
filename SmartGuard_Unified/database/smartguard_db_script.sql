-- ==============================================================================
-- DỰ ÁN: SMARTGUARD UNIFIED — CAPYBARA SECURITY EDITION
-- TỆP: database/smartguard_db_script.sql
-- MỤC ĐÍCH: Kịch bản khởi tạo cấu trúc CSDL toàn bộ hệ thống (DDL) và nạp dữ liệu mẫu (DML).
-- TƯƠNG THÍCH: Microsoft SQL Server 2017 / 2019 / 2022 / LocalDB / Somee Cloud MSSQL
-- TÍNH CHẤT: Idempotent (Chạy an toàn nhiều lần không gây lỗi trùng lặp)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- 0. TẠO & CHỌN CƠ SỞ DỮ LIỆU (Bỏ chú thích nếu chạy trên SQL Server cục bộ / LocalDB)
-- ------------------------------------------------------------------------------
/*
IF NOT EXISTS (SELECT * FROM sys.databases WHERE name = N'smartguard_db')
BEGIN
    CREATE DATABASE [smartguard_db];
END
GO

USE [smartguard_db];
GO
*/

-- ------------------------------------------------------------------------------
-- 1. BẢNG QUẢN LÝ LỊCH SỬ MIGRATION CỦA ENTITY FRAMEWORK CORE
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'__EFMigrationsHistory' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[__EFMigrationsHistory] (
        [MigrationId] NVARCHAR(150) NOT NULL,
        [ProductVersion] NVARCHAR(32) NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY CLUSTERED ([MigrationId] ASC)
    );
END;
GO

-- ------------------------------------------------------------------------------
-- 2. BẢNG [Users]: Người dùng hệ thống (Admin, Owner, Member)
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'Users' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[Users] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [Email] NVARCHAR(100) NOT NULL,
        [Username] NVARCHAR(50) NOT NULL,
        [PasswordHash] NVARCHAR(MAX) NOT NULL,
        [Role] NVARCHAR(20) NOT NULL DEFAULT N'Owner', -- 'Admin' | 'Owner' | 'Member'
        [EmailVerified] BIT NOT NULL DEFAULT 1,
        [IsLocked] BIT NOT NULL DEFAULT 0,
        [CreatedAt] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_Users] PRIMARY KEY CLUSTERED ([Id] ASC)
    );

    CREATE UNIQUE NONCLUSTERED INDEX [IX_Users_Email] ON [dbo].[Users] ([Email] ASC);
    CREATE UNIQUE NONCLUSTERED INDEX [IX_Users_Username] ON [dbo].[Users] ([Username] ASC);
END;
GO

-- ------------------------------------------------------------------------------
-- 3. BẢNG [OtpChallenges]: Quản lý mã xác thực 2 lớp (2FA) & Đăng nhập
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'OtpChallenges' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[OtpChallenges] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [UserId] UNIQUEIDENTIFIER NOT NULL,
        [Purpose] NVARCHAR(30) NOT NULL DEFAULT N'Login', -- 'Login' | 'VerifyEmail' | 'ResetPassword'
        [CodeHash] NVARCHAR(MAX) NOT NULL,
        [Attempts] INT NOT NULL DEFAULT 0,
        [ExpiresAt] DATETIME2 NOT NULL,
        [UsedAt] DATETIME2 NULL,
        CONSTRAINT [PK_OtpChallenges] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_OtpChallenges_Users_UserId] FOREIGN KEY ([UserId]) 
            REFERENCES [dbo].[Users] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_OtpChallenges_UserId] ON [dbo].[OtpChallenges] ([UserId] ASC);
END;
GO

-- ------------------------------------------------------------------------------
-- 4. BẢNG [Zones]: Khu vực / Phân vùng lắp đặt (Phòng khách, Cổng chính, Sân sau...)
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'Zones' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[Zones] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [OwnerId] UNIQUEIDENTIFIER NOT NULL,
        [Name] NVARCHAR(100) NOT NULL,
        [Description] NVARCHAR(255) NOT NULL DEFAULT N'',
        CONSTRAINT [PK_Zones] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_Zones_Users_OwnerId] FOREIGN KEY ([OwnerId]) 
            REFERENCES [dbo].[Users] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_Zones_OwnerId] ON [dbo].[Zones] ([OwnerId] ASC);
END;
GO

-- ------------------------------------------------------------------------------
-- 5. BẢNG [Devices]: Thiết bị an ninh IoT (Camera, Cảm biến, Chuông cửa, Còi hú)
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'Devices' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[Devices] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [OwnerId] UNIQUEIDENTIFIER NOT NULL,
        [ZoneId] UNIQUEIDENTIFIER NULL,
        [Name] NVARCHAR(100) NOT NULL,
        [DeviceCode] NVARCHAR(50) NOT NULL,
        [Description] NVARCHAR(255) NOT NULL DEFAULT N'',
        [IsArmed] BIT NOT NULL DEFAULT 1,
        [NoiseThreshold] FLOAT NOT NULL DEFAULT 70.0,
        [MotionThreshold] FLOAT NOT NULL DEFAULT 3.5,
        [RegisteredAt] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        [LastSeenAt] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_Devices] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_Devices_Users_OwnerId] FOREIGN KEY ([OwnerId]) 
            REFERENCES [dbo].[Users] ([Id]) ON DELETE CASCADE,
        CONSTRAINT [FK_Devices_Zones_ZoneId] FOREIGN KEY ([ZoneId]) 
            REFERENCES [dbo].[Zones] ([Id]) ON DELETE SET NULL
    );

    CREATE UNIQUE NONCLUSTERED INDEX [IX_Devices_DeviceCode] ON [dbo].[Devices] ([DeviceCode] ASC);
    CREATE NONCLUSTERED INDEX [IX_Devices_OwnerId] ON [dbo].[Devices] ([OwnerId] ASC);
    CREATE NONCLUSTERED INDEX [IX_Devices_ZoneId] ON [dbo].[Devices] ([ZoneId] ASC);
END;
GO

-- ------------------------------------------------------------------------------
-- 6. BẢNG [MemberAccesses]: Phân quyền truy cập thiết bị gia đình cho thành viên
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'MemberAccesses' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[MemberAccesses] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [OwnerId] UNIQUEIDENTIFIER NOT NULL,
        [MemberUserId] UNIQUEIDENTIFIER NOT NULL,
        [DeviceId] UNIQUEIDENTIFIER NULL, -- NULL => Có quyền trên toàn bộ camera của Owner
        [CanAcknowledge] BIT NOT NULL DEFAULT 1,
        [CreatedAt] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_MemberAccesses] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_MemberAccesses_Users_MemberUserId] FOREIGN KEY ([MemberUserId]) 
            REFERENCES [dbo].[Users] ([Id]) ON DELETE NO ACTION,
        CONSTRAINT [FK_MemberAccesses_Devices_DeviceId] FOREIGN KEY ([DeviceId]) 
            REFERENCES [dbo].[Devices] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_MemberAccesses_MemberUserId] ON [dbo].[MemberAccesses] ([MemberUserId] ASC);
    CREATE NONCLUSTERED INDEX [IX_MemberAccesses_DeviceId] ON [dbo].[MemberAccesses] ([DeviceId] ASC);
END;
GO

-- ------------------------------------------------------------------------------
-- 7. BẢNG [AlertEvents]: Nhật ký sự kiện báo động & Diễn giải nguồn gốc (Adaptive)
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'AlertEvents' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[AlertEvents] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [DeviceId] UNIQUEIDENTIFIER NOT NULL,
        [TriggerReason] NVARCHAR(50) NOT NULL DEFAULT N'CHUYEN_DONG', -- 'RUNG_LAC' | 'TIENG_DONG' | 'NGUOI_LA' | 'VO_KINH'
        [TriggerScore] FLOAT NOT NULL DEFAULT 0.0,
        [Severity] NVARCHAR(20) NOT NULL DEFAULT N'Warning', -- 'Info' | 'Warning' | 'Critical'
        [TriggeredAt] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        [ImageUrl] NVARCHAR(MAX) NULL,
        [DiscordMessageId] NVARCHAR(MAX) NULL,
        [AcknowledgedBy] UNIQUEIDENTIFIER NULL,
        [AcknowledgedAt] DATETIME2 NULL,
        [Status] NVARCHAR(100) NOT NULL DEFAULT N'Triggered', -- 'Triggered' | 'Dismissed' | 'Confirmed'
        [AdaptiveReason] NVARCHAR(255) NULL,
        CONSTRAINT [PK_AlertEvents] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_AlertEvents_Devices_DeviceId] FOREIGN KEY ([DeviceId]) 
            REFERENCES [dbo].[Devices] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_AlertEvents_DeviceId] ON [dbo].[AlertEvents] ([DeviceId] ASC);
    CREATE NONCLUSTERED INDEX [IX_AlertEvents_TriggeredAt] ON [dbo].[AlertEvents] ([TriggeredAt] DESC);
END;
GO

-- ------------------------------------------------------------------------------
-- 8. BẢNG [EvidenceImages]: Ảnh chụp bằng chứng hiện trường từ Camera
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'EvidenceImages' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[EvidenceImages] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [AlertEventId] UNIQUEIDENTIFIER NULL,
        [DeviceId] UNIQUEIDENTIFIER NOT NULL,
        [FileName] NVARCHAR(255) NOT NULL,
        [RelativeUrl] NVARCHAR(500) NOT NULL,
        [UploadedAt] DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        CONSTRAINT [PK_EvidenceImages] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_EvidenceImages_AlertEvents_AlertEventId] FOREIGN KEY ([AlertEventId]) 
            REFERENCES [dbo].[AlertEvents] ([Id]) ON DELETE SET NULL
    );

    CREATE NONCLUSTERED INDEX [IX_EvidenceImages_AlertEventId] ON [dbo].[EvidenceImages] ([AlertEventId] ASC);
END;
GO

-- ------------------------------------------------------------------------------
-- 9. BẢNG [AdaptiveProfiles]: Hồ sơ kịch bản bảo mật thích ứng (Home / Away / Night)
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'AdaptiveProfiles' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[AdaptiveProfiles] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [UserId] UNIQUEIDENTIFIER NOT NULL,
        [ModeName] NVARCHAR(50) NOT NULL, -- 'Home' | 'Away' | 'Night' | 'Custom'
        [DisplayName] NVARCHAR(100) NOT NULL,
        [Description] NVARCHAR(255) NOT NULL DEFAULT N'',
        [IsActive] BIT NOT NULL DEFAULT 0,
        [ActiveFrom] NVARCHAR(5) NOT NULL DEFAULT N'00:00',
        [ActiveTo] NVARCHAR(5) NOT NULL DEFAULT N'23:59',
        [BehaviorOnDisconnect] NVARCHAR(50) NOT NULL DEFAULT N'AlertOffline',
        [SnoozeUntil] DATETIME2 NULL,
        CONSTRAINT [PK_AdaptiveProfiles] PRIMARY KEY CLUSTERED ([Id] ASC)
    );

    CREATE NONCLUSTERED INDEX [IX_AdaptiveProfiles_UserId] ON [dbo].[AdaptiveProfiles] ([UserId] ASC);
END;
GO

-- ------------------------------------------------------------------------------
-- 10. BẢNG [AdaptiveZoneRules]: Quy tắc lọc & độ nhạy cảm biến theo phân vùng
-- ------------------------------------------------------------------------------
IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = N'AdaptiveZoneRules' AND schema_id = SCHEMA_ID(N'dbo'))
BEGIN
    CREATE TABLE [dbo].[AdaptiveZoneRules] (
        [Id] UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID(),
        [ProfileId] UNIQUEIDENTIFIER NOT NULL,
        [ZoneId] UNIQUEIDENTIFIER NOT NULL,
        [EnableMonitoring] BIT NOT NULL DEFAULT 1,
        [EnableAlarmSound] BIT NOT NULL DEFAULT 1,
        [EnableDiscordNotification] BIT NOT NULL DEFAULT 1,
        [CustomSensitivity] FLOAT NOT NULL DEFAULT 1.0, -- Hệ số nhân: 0.5 .. 2.0
        CONSTRAINT [PK_AdaptiveZoneRules] PRIMARY KEY CLUSTERED ([Id] ASC),
        CONSTRAINT [FK_AdaptiveZoneRules_AdaptiveProfiles_ProfileId] FOREIGN KEY ([ProfileId]) 
            REFERENCES [dbo].[AdaptiveProfiles] ([Id]) ON DELETE CASCADE,
        CONSTRAINT [FK_AdaptiveZoneRules_Zones_ZoneId] FOREIGN KEY ([ZoneId]) 
            REFERENCES [dbo].[Zones] ([Id]) ON DELETE CASCADE
    );

    CREATE NONCLUSTERED INDEX [IX_AdaptiveZoneRules_ProfileId] ON [dbo].[AdaptiveZoneRules] ([ProfileId] ASC);
    CREATE NONCLUSTERED INDEX [IX_AdaptiveZoneRules_ZoneId] ON [dbo].[AdaptiveZoneRules] ([ZoneId] ASC);
END;
GO

-- ==============================================================================
-- 11. DỮ LIỆU MẪU KHỞI TẠO (SEED DATA)
-- ==============================================================================

-- A. Ghi nhận Migration Entity Framework Core
IF NOT EXISTS (SELECT 1 FROM [dbo].[__EFMigrationsHistory] WHERE [MigrationId] = N'20261102173009_InitialCreate')
BEGIN
    INSERT INTO [dbo].[__EFMigrationsHistory] ([MigrationId], [ProductVersion])
    VALUES (N'20261102173009_InitialCreate', N'8.0.10');
END;
GO

-- B. Tạo Tài khoản Quản trị viên (Admin) mặc định
-- Mật khẩu giải mã: Admin123@ (được mã hóa theo chuẩn BCrypt WorkFactor 11)
DECLARE @AdminId UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
IF NOT EXISTS (SELECT 1 FROM [dbo].[Users] WHERE [Email] = N'admin@smartguard.local')
BEGIN
    INSERT INTO [dbo].[Users] ([Id], [Email], [Username], [PasswordHash], [Role], [EmailVerified], [IsLocked], [CreatedAt])
    VALUES (
        @AdminId,
        N'admin@smartguard.local',
        N'admin',
        N'$2a$11$.ZdJU8D..qtBjLWlzMQ7leIOR97mFIEiAdTpA6D.3MvaL6wfPHtqu', -- 'Admin123@'
        N'Admin',
        1,
        0,
        SYSUTCDATETIME()
    );
END
ELSE
BEGIN
    SELECT @AdminId = [Id] FROM [dbo].[Users] WHERE [Email] = N'admin@smartguard.local';
END;

-- C. Tạo Tài khoản Chủ nhà mẫu (Owner)
-- Mật khẩu giải mã: Password123@
DECLARE @OwnerId UNIQUEIDENTIFIER = '22222222-2222-2222-2222-222222222222';
IF NOT EXISTS (SELECT 1 FROM [dbo].[Users] WHERE [Email] = N'user@smartguard.local')
BEGIN
    INSERT INTO [dbo].[Users] ([Id], [Email], [Username], [PasswordHash], [Role], [EmailVerified], [IsLocked], [CreatedAt])
    VALUES (
        @OwnerId,
        N'user@smartguard.local',
        N'homeowner',
        N'$2a$11$7qn12U5aN5Mo7H.MFDjlNu4CfwPOM3p2kRx4Lflv3j.XnjI.6sVsy', -- 'Password123@'
        N'Owner',
        1,
        0,
        SYSUTCDATETIME()
    );
END
ELSE
BEGIN
    SELECT @OwnerId = [Id] FROM [dbo].[Users] WHERE [Email] = N'user@smartguard.local';
END;

-- D. Tạo Tài khoản Thành viên mẫu (Member)
DECLARE @MemberId UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
IF NOT EXISTS (SELECT 1 FROM [dbo].[Users] WHERE [Email] = N'member@smartguard.local')
BEGIN
    INSERT INTO [dbo].[Users] ([Id], [Email], [Username], [PasswordHash], [Role], [EmailVerified], [IsLocked], [CreatedAt])
    VALUES (
        @MemberId,
        N'member@smartguard.local',
        N'member1',
        N'$2a$11$7qn12U5aN5Mo7H.MFDjlNu4CfwPOM3p2kRx4Lflv3j.XnjI.6sVsy', -- 'Password123@'
        N'Member',
        1,
        0,
        SYSUTCDATETIME()
    );
END;

-- E. Tạo các Phân vùng mẫu (Zones) cho Chủ nhà
DECLARE @ZoneLivingId UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444441';
DECLARE @ZoneGateId UNIQUEIDENTIFIER   = '44444444-4444-4444-4444-444444444442';
DECLARE @ZoneYardId UNIQUEIDENTIFIER   = '44444444-4444-4444-4444-444444444443';
DECLARE @ZoneBalconyId UNIQUEIDENTIFIER= '44444444-4444-4444-4444-444444444444';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Phòng khách')
    INSERT INTO [dbo].[Zones] ([Id], [OwnerId], [Name], [Description]) VALUES (@ZoneLivingId, @OwnerId, N'Phòng khách', N'Khu vực sinh hoạt chung tầng trệt');

IF NOT EXISTS (SELECT 1 FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Cổng chính')
    INSERT INTO [dbo].[Zones] ([Id], [OwnerId], [Name], [Description]) VALUES (@ZoneGateId, @OwnerId, N'Cổng chính', N'Lối ra vào chính phía trước ngôi nhà');

IF NOT EXISTS (SELECT 1 FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Sân trước')
    INSERT INTO [dbo].[Zones] ([Id], [OwnerId], [Name], [Description]) VALUES (@ZoneYardId, @OwnerId, N'Sân trước', N'Khu vực để xe và sân vườn phía trước');

IF NOT EXISTS (SELECT 1 FROM [dbo].[Zones] WHERE [OwnerId] = @OwnerId AND [Name] = N'Ban công')
    INSERT INTO [dbo].[Zones] ([Id], [OwnerId], [Name], [Description]) VALUES (@ZoneBalconyId, @OwnerId, N'Ban công', N'Ban công lầu 1 hướng ra mặt tiền');

-- F. Tạo Thiết bị an ninh IoT mẫu (Devices)
DECLARE @DevCamGateId UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555551';
DECLARE @DevSensLivingId UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555552';
DECLARE @DevDoorbellId UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555553';

IF NOT EXISTS (SELECT 1 FROM [dbo].[Devices] WHERE [DeviceCode] = N'CAM-GATE-01')
BEGIN
    INSERT INTO [dbo].[Devices] ([Id], [OwnerId], [ZoneId], [Name], [DeviceCode], [Description], [IsArmed], [NoiseThreshold], [MotionThreshold], [RegisteredAt], [LastSeenAt])
    VALUES (
        @DevCamGateId,
        @OwnerId,
        @ZoneGateId,
        N'Camera Cổng Chính',
        N'CAM-GATE-01',
        N'IP: 192.168.1.101 | Vị trí: Cửa chính | Loại: camera',
        1,
        70.0,
        3.5,
        SYSUTCDATETIME(),
        SYSUTCDATETIME()
    );
END;

IF NOT EXISTS (SELECT 1 FROM [dbo].[Devices] WHERE [DeviceCode] = N'SEN-LIV-01')
BEGIN
    INSERT INTO [dbo].[Devices] ([Id], [OwnerId], [ZoneId], [Name], [DeviceCode], [Description], [IsArmed], [NoiseThreshold], [MotionThreshold], [RegisteredAt], [LastSeenAt])
    VALUES (
        @DevSensLivingId,
        @OwnerId,
        @ZoneLivingId,
        N'Cảm biến Rung Phòng Khách',
        N'SEN-LIV-01',
        N'IP: 192.168.1.102 | Vị trí: Phòng khách | Loại: sensor',
        1,
        65.0,
        2.8,
        SYSUTCDATETIME(),
        SYSUTCDATETIME()
    );
END;

IF NOT EXISTS (SELECT 1 FROM [dbo].[Devices] WHERE [DeviceCode] = N'BELL-GATE-01')
BEGIN
    INSERT INTO [dbo].[Devices] ([Id], [OwnerId], [ZoneId], [Name], [DeviceCode], [Description], [IsArmed], [NoiseThreshold], [MotionThreshold], [RegisteredAt], [LastSeenAt])
    VALUES (
        @DevDoorbellId,
        @OwnerId,
        @ZoneGateId,
        N'Chuông cửa Cổng Trước',
        N'BELL-GATE-01',
        N'IP: 192.168.1.103 | Vị trí: Cửa chính | Loại: doorbell',
        1,
        75.0,
        4.0,
        SYSUTCDATETIME(),
        SYSUTCDATETIME()
    );
END;

-- G. Chia sẻ quyền truy cập Camera cho Thành viên mẫu
IF NOT EXISTS (SELECT 1 FROM [dbo].[MemberAccesses] WHERE [OwnerId] = @OwnerId AND [MemberUserId] = @MemberId)
BEGIN
    INSERT INTO [dbo].[MemberAccesses] ([Id], [OwnerId], [MemberUserId], [DeviceId], [CanAcknowledge], [CreatedAt])
    VALUES (
        NEWID(),
        @OwnerId,
        @MemberId,
        @DevCamGateId,
        1,
        SYSUTCDATETIME()
    );
END;

-- H. Tạo 3 Hồ sơ Thích ứng Tiêu chuẩn (Adaptive Profiles)
DECLARE @ProfileHomeId UNIQUEIDENTIFIER  = '66666666-6666-6666-6666-666666666661';
DECLARE @ProfileAwayId UNIQUEIDENTIFIER  = '66666666-6666-6666-6666-666666666662';
DECLARE @ProfileNightId UNIQUEIDENTIFIER = '66666666-6666-6666-6666-666666666663';

-- 1. Chế độ Ở nhà (Home) - Kích hoạt mặc định
IF NOT EXISTS (SELECT 1 FROM [dbo].[AdaptiveProfiles] WHERE [UserId] = @OwnerId AND [ModeName] = N'Home')
BEGIN
    INSERT INTO [dbo].[AdaptiveProfiles] ([Id], [UserId], [ModeName], [DisplayName], [Description], [IsActive], [ActiveFrom], [ActiveTo], [BehaviorOnDisconnect])
    VALUES (
        @ProfileHomeId,
        @OwnerId,
        N'Home',
        N'Ở nhà',
        N'Giảm cảnh báo tại các khu vực sinh hoạt trong nhà, tập trung bảo vệ lối vào/sân ngoài.',
        1,
        N'00:00',
        N'23:59',
        N'AlertOffline'
    );

    -- Quy tắc phân vùng cho Home: Phòng khách (miễn trừ), Cổng chính (bảo vệ)
    INSERT INTO [dbo].[AdaptiveZoneRules] ([Id], [ProfileId], [ZoneId], [EnableMonitoring], [EnableAlarmSound], [EnableDiscordNotification], [CustomSensitivity])
    VALUES 
        (NEWID(), @ProfileHomeId, @ZoneLivingId, 0, 0, 1, 0.8), -- Miễn trừ phòng khách
        (NEWID(), @ProfileHomeId, @ZoneGateId,   1, 1, 1, 1.0); -- Bảo vệ cổng
END;

-- 2. Chế độ Rời nhà (Away)
IF NOT EXISTS (SELECT 1 FROM [dbo].[AdaptiveProfiles] WHERE [UserId] = @OwnerId AND [ModeName] = N'Away')
BEGIN
    INSERT INTO [dbo].[AdaptiveProfiles] ([Id], [UserId], [ModeName], [DisplayName], [Description], [IsActive], [ActiveFrom], [ActiveTo], [BehaviorOnDisconnect])
    VALUES (
        @ProfileAwayId,
        @OwnerId,
        N'Away',
        N'Rời nhà',
        N'Tăng cường giám sát tối đa trên tất cả các khu vực, gửi thông báo khẩn cấp ngay lập tức.',
        0,
        N'00:00',
        N'23:59',
        N'FailSecure'
    );

    INSERT INTO [dbo].[AdaptiveZoneRules] ([Id], [ProfileId], [ZoneId], [EnableMonitoring], [EnableAlarmSound], [EnableDiscordNotification], [CustomSensitivity])
    VALUES 
        (NEWID(), @ProfileAwayId, @ZoneLivingId, 1, 1, 1, 1.2),
        (NEWID(), @ProfileAwayId, @ZoneGateId,   1, 1, 1, 1.2);
END;

-- 3. Chế độ Ban đêm (Night)
IF NOT EXISTS (SELECT 1 FROM [dbo].[AdaptiveProfiles] WHERE [UserId] = @OwnerId AND [ModeName] = N'Night')
BEGIN
    INSERT INTO [dbo].[AdaptiveProfiles] ([Id], [UserId], [ModeName], [DisplayName], [Description], [IsActive], [ActiveFrom], [ActiveTo], [BehaviorOnDisconnect])
    VALUES (
        @ProfileNightId,
        @OwnerId,
        N'Night',
        N'Ban đêm',
        N'Điều chỉnh vùng giám sát ban đêm với độ nhạy cao (x1.5), kích hoạt còi tại chỗ lập tức.',
        0,
        N'22:00',
        N'06:00',
        N'FailSecure'
    );

    INSERT INTO [dbo].[AdaptiveZoneRules] ([Id], [ProfileId], [ZoneId], [EnableMonitoring], [EnableAlarmSound], [EnableDiscordNotification], [CustomSensitivity])
    VALUES 
        (NEWID(), @ProfileNightId, @ZoneLivingId, 1, 1, 1, 1.5),
        (NEWID(), @ProfileNightId, @ZoneGateId,   1, 1, 1, 1.5);
END;

-- I. Tạo Sự kiện Cảnh báo Mẫu (Alert Events)
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
    VALUES (
        NEWID(),
        @AlertEventId,
        @DevCamGateId,
        N'sample_alert.jpg',
        N'/evidence/sample_alert.jpg',
        DATEADD(MINUTE, -15, SYSUTCDATETIME())
    );
END;
GO

-- ==============================================================================
-- KIỂM TRA TỔNG KẾT SAU KHI THI HÀNH
-- ==============================================================================
PRINT N'';
PRINT N'==============================================================================';
PRINT N'✅ THI HÀNH SCRIPT SQL SMARTGUARD UNIFIED THÀNH CÔNG!';
PRINT N'==============================================================================';
PRINT N'• Đã khởi tạo đầy đủ 9 bảng CSDL + Bảng lịch sử EF Migrations.';
PRINT N'• Tài khoản Admin: admin@smartguard.local / Mật khẩu: Admin123@';
PRINT N'• Tài khoản Owner: user@smartguard.local  / Mật khẩu: Password123@';
PRINT N'• Thiết bị IoT mẫu: Camera Cổng Chính, Cảm biến Rung Phòng Khách, Chuông cửa.';
PRINT N'• 3 Chế độ Adaptive Security: Ở nhà (Home - Active), Rời nhà (Away), Ban đêm (Night).';
PRINT N'==============================================================================';
GO

