-- 1. Tạo mới hoặc cập nhật lại mật khẩu chuẩn cho tài khoản Admin
IF NOT EXISTS (SELECT 1 FROM [dbo].[Users] WHERE [Email] = N'admin@smartguard.local' OR [Username] = N'admin')
BEGIN
    INSERT INTO [dbo].[Users] (
        [Id], [Email], [Username], [PasswordHash], [Role], [EmailVerified], [IsLocked], [CreatedAt]
    )
    VALUES (
        '11111111-1111-1111-1111-111111111111',
        N'admin@smartguard.local',
        N'admin',
        N'$2a$11$.ZdJU8D..qtBjLWlzMQ7leIOR97mFIEiAdTpA6D.3MvaL6wfPHtqu', -- Mật khẩu: Admin123@
        N'Admin',
        1,
        0,
        SYSUTCDATETIME()
    );
END
ELSE
BEGIN
    UPDATE [dbo].[Users]
    SET [Email]         = N'admin@smartguard.local',
        [Username]      = N'admin',
        [PasswordHash]  = N'$2a$11$.ZdJU8D..qtBjLWlzMQ7leIOR97mFIEiAdTpA6D.3MvaL6wfPHtqu', -- Mật khẩu: Admin123@
        [Role]          = N'Admin',
        [EmailVerified] = 1,
        [IsLocked]      = 0
    WHERE [Email] = N'admin@smartguard.local' OR [Username] = N'admin';
END;

-- 2. (Tuỳ chọn) Tạo hoặc cập nhật tài khoản Chủ nhà mẫu (Owner)
IF NOT EXISTS (SELECT 1 FROM [dbo].[Users] WHERE [Email] = N'user@smartguard.local' OR [Username] = N'homeowner')
BEGIN
    INSERT INTO [dbo].[Users] (
        [Id], [Email], [Username], [PasswordHash], [Role], [EmailVerified], [IsLocked], [CreatedAt]
    )
    VALUES (
        '22222222-2222-2222-2222-222222222222',
        N'user@smartguard.local',
        N'homeowner',
        N'$2a$11$7qn12U5aN5Mo7H.MFDjlNu4CfwPOM3p2kRx4Lflv3j.XnjI.6sVsy', -- Mật khẩu: Password123@
        N'Owner',
        1,
        0,
        SYSUTCDATETIME()
    );
END
ELSE
BEGIN
    UPDATE [dbo].[Users]
    SET [Email]         = N'user@smartguard.local',
        [Username]      = N'homeowner',
        [PasswordHash]  = N'$2a$11$7qn12U5aN5Mo7H.MFDjlNu4CfwPOM3p2kRx4Lflv3j.XnjI.6sVsy', -- Mật khẩu: Password123@
        [Role]          = N'Owner',
        [EmailVerified] = 1,
        [IsLocked]      = 0
    WHERE [Email] = N'user@smartguard.local' OR [Username] = N'homeowner';
END;

-- 3. Kiểm tra danh sách tài khoản sau khi chạy
SELECT [Id], [Username], [Email], [Role], [EmailVerified], [IsLocked], [CreatedAt]
FROM [dbo].[Users];