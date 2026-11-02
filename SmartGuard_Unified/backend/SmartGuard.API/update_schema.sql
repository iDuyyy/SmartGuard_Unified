IF OBJECT_ID(N'[__EFMigrationsHistory]') IS NULL
BEGIN
    CREATE TABLE [__EFMigrationsHistory] (
        [MigrationId] nvarchar(150) NOT NULL,
        [ProductVersion] nvarchar(32) NOT NULL,
        CONSTRAINT [PK___EFMigrationsHistory] PRIMARY KEY ([MigrationId])
    );
END;
GO

BEGIN TRANSACTION;
GO

CREATE TABLE [AdaptiveProfiles] (
    [Id] uniqueidentifier NOT NULL,
    [UserId] uniqueidentifier NOT NULL,
    [ModeName] nvarchar(50) NOT NULL,
    [DisplayName] nvarchar(100) NOT NULL,
    [Description] nvarchar(255) NOT NULL,
    [IsActive] bit NOT NULL,
    [ActiveFrom] nvarchar(5) NOT NULL,
    [ActiveTo] nvarchar(5) NOT NULL,
    [BehaviorOnDisconnect] nvarchar(50) NOT NULL,
    [SnoozeUntil] datetime2 NULL,
    CONSTRAINT [PK_AdaptiveProfiles] PRIMARY KEY ([Id])
);
GO

CREATE TABLE [OtpChallenges] (
    [Id] uniqueidentifier NOT NULL,
    [UserId] uniqueidentifier NOT NULL,
    [Purpose] nvarchar(30) NOT NULL,
    [CodeHash] nvarchar(max) NOT NULL,
    [Attempts] int NOT NULL,
    [ExpiresAt] datetime2 NOT NULL,
    [UsedAt] datetime2 NULL,
    CONSTRAINT [PK_OtpChallenges] PRIMARY KEY ([Id])
);
GO

CREATE TABLE [Users] (
    [Id] uniqueidentifier NOT NULL,
    [Email] nvarchar(100) NOT NULL,
    [Username] nvarchar(50) NOT NULL,
    [PasswordHash] nvarchar(max) NOT NULL,
    [Role] nvarchar(20) NOT NULL,
    [EmailVerified] bit NOT NULL,
    [IsLocked] bit NOT NULL,
    [CreatedAt] datetime2 NOT NULL,
    CONSTRAINT [PK_Users] PRIMARY KEY ([Id])
);
GO

CREATE TABLE [Zones] (
    [Id] uniqueidentifier NOT NULL,
    [OwnerId] uniqueidentifier NOT NULL,
    [Name] nvarchar(100) NOT NULL,
    [Description] nvarchar(255) NOT NULL,
    CONSTRAINT [PK_Zones] PRIMARY KEY ([Id]),
    CONSTRAINT [FK_Zones_Users_OwnerId] FOREIGN KEY ([OwnerId]) REFERENCES [Users] ([Id]) ON DELETE CASCADE
);
GO

CREATE TABLE [AdaptiveZoneRules] (
    [Id] uniqueidentifier NOT NULL,
    [ProfileId] uniqueidentifier NOT NULL,
    [ZoneId] uniqueidentifier NOT NULL,
    [EnableMonitoring] bit NOT NULL,
    [EnableAlarmSound] bit NOT NULL,
    [EnableDiscordNotification] bit NOT NULL,
    [CustomSensitivity] float NOT NULL,
    CONSTRAINT [PK_AdaptiveZoneRules] PRIMARY KEY ([Id]),
    CONSTRAINT [FK_AdaptiveZoneRules_AdaptiveProfiles_ProfileId] FOREIGN KEY ([ProfileId]) REFERENCES [AdaptiveProfiles] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_AdaptiveZoneRules_Zones_ZoneId] FOREIGN KEY ([ZoneId]) REFERENCES [Zones] ([Id]) ON DELETE CASCADE
);
GO

CREATE TABLE [Devices] (
    [Id] uniqueidentifier NOT NULL,
    [OwnerId] uniqueidentifier NOT NULL,
    [ZoneId] uniqueidentifier NULL,
    [Name] nvarchar(100) NOT NULL,
    [DeviceCode] nvarchar(50) NOT NULL,
    [Description] nvarchar(255) NOT NULL,
    [IsArmed] bit NOT NULL,
    [NoiseThreshold] float NOT NULL,
    [MotionThreshold] float NOT NULL,
    [RegisteredAt] datetime2 NOT NULL,
    [LastSeenAt] datetime2 NOT NULL,
    CONSTRAINT [PK_Devices] PRIMARY KEY ([Id]),
    CONSTRAINT [FK_Devices_Users_OwnerId] FOREIGN KEY ([OwnerId]) REFERENCES [Users] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_Devices_Zones_ZoneId] FOREIGN KEY ([ZoneId]) REFERENCES [Zones] ([Id])
);
GO

CREATE TABLE [AlertEvents] (
    [Id] uniqueidentifier NOT NULL,
    [DeviceId] uniqueidentifier NOT NULL,
    [TriggerReason] nvarchar(50) NOT NULL,
    [TriggerScore] float NOT NULL,
    [Severity] nvarchar(20) NOT NULL,
    [TriggeredAt] datetime2 NOT NULL,
    [ImageUrl] nvarchar(max) NULL,
    [DiscordMessageId] nvarchar(max) NULL,
    [AcknowledgedBy] uniqueidentifier NULL,
    [AcknowledgedAt] datetime2 NULL,
    [Status] nvarchar(100) NOT NULL,
    [AdaptiveReason] nvarchar(255) NULL,
    CONSTRAINT [PK_AlertEvents] PRIMARY KEY ([Id]),
    CONSTRAINT [FK_AlertEvents_Devices_DeviceId] FOREIGN KEY ([DeviceId]) REFERENCES [Devices] ([Id]) ON DELETE CASCADE
);
GO

CREATE TABLE [MemberAccesses] (
    [Id] uniqueidentifier NOT NULL,
    [OwnerId] uniqueidentifier NOT NULL,
    [MemberUserId] uniqueidentifier NOT NULL,
    [DeviceId] uniqueidentifier NULL,
    [CanAcknowledge] bit NOT NULL,
    [CreatedAt] datetime2 NOT NULL,
    CONSTRAINT [PK_MemberAccesses] PRIMARY KEY ([Id]),
    CONSTRAINT [FK_MemberAccesses_Devices_DeviceId] FOREIGN KEY ([DeviceId]) REFERENCES [Devices] ([Id]) ON DELETE CASCADE,
    CONSTRAINT [FK_MemberAccesses_Users_MemberUserId] FOREIGN KEY ([MemberUserId]) REFERENCES [Users] ([Id]) ON DELETE NO ACTION
);
GO

CREATE TABLE [EvidenceImages] (
    [Id] uniqueidentifier NOT NULL,
    [AlertEventId] uniqueidentifier NULL,
    [DeviceId] uniqueidentifier NOT NULL,
    [FileName] nvarchar(255) NOT NULL,
    [RelativeUrl] nvarchar(500) NOT NULL,
    [UploadedAt] datetime2 NOT NULL,
    CONSTRAINT [PK_EvidenceImages] PRIMARY KEY ([Id]),
    CONSTRAINT [FK_EvidenceImages_AlertEvents_AlertEventId] FOREIGN KEY ([AlertEventId]) REFERENCES [AlertEvents] ([Id])
);
GO

CREATE INDEX [IX_AdaptiveZoneRules_ProfileId] ON [AdaptiveZoneRules] ([ProfileId]);
GO

CREATE INDEX [IX_AdaptiveZoneRules_ZoneId] ON [AdaptiveZoneRules] ([ZoneId]);
GO

CREATE INDEX [IX_AlertEvents_DeviceId] ON [AlertEvents] ([DeviceId]);
GO

CREATE UNIQUE INDEX [IX_Devices_DeviceCode] ON [Devices] ([DeviceCode]);
GO

CREATE INDEX [IX_Devices_OwnerId] ON [Devices] ([OwnerId]);
GO

CREATE INDEX [IX_Devices_ZoneId] ON [Devices] ([ZoneId]);
GO

CREATE INDEX [IX_EvidenceImages_AlertEventId] ON [EvidenceImages] ([AlertEventId]);
GO

CREATE INDEX [IX_MemberAccesses_DeviceId] ON [MemberAccesses] ([DeviceId]);
GO

CREATE INDEX [IX_MemberAccesses_MemberUserId] ON [MemberAccesses] ([MemberUserId]);
GO

CREATE UNIQUE INDEX [IX_Users_Email] ON [Users] ([Email]);
GO

CREATE UNIQUE INDEX [IX_Users_Username] ON [Users] ([Username]);
GO

CREATE INDEX [IX_Zones_OwnerId] ON [Zones] ([OwnerId]);
GO

INSERT INTO [__EFMigrationsHistory] ([MigrationId], [ProductVersion])
VALUES (N'20261102173009_InitialCreate', N'8.0.3');
GO

COMMIT;
GO

