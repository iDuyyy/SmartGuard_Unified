using System.Text;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using SmartGuard.API.Data;
using SmartGuard.API.Models;
using SmartGuard.API.Services.Discord;
using SmartGuard.API.Services.Email;
using SmartGuard.API.Services.Security;

var builder = WebApplication.CreateBuilder(args);

// 0. Hỗ trợ dọn sạch Database bằng lệnh: dotnet run --project backend/SmartGuard.API -- --clean-db
if (args.Contains("--clean-db"))
{
    var rawCs = builder.Configuration.GetConnectionString("DefaultConnection")
        ?? "Server=DESKTOP-IIQVP6N;Database=SmartGuard_Unified_DB;Trusted_Connection=True;TrustServerCertificate=True;";
    var cleanCs = rawCs.Contains("Connect Timeout=", StringComparison.OrdinalIgnoreCase)
        ? rawCs
        : $"{rawCs.TrimEnd(';')};Connect Timeout=30;";
    var optBuilder = new DbContextOptionsBuilder<SmartGuardDbContext>();
    optBuilder.UseSqlServer(cleanCs, sql =>
        sql.EnableRetryOnFailure(maxRetryCount: 3, maxRetryDelay: TimeSpan.FromSeconds(3), errorNumbersToAdd: null));
    using var cleanDb = new SmartGuardDbContext(optBuilder.Options);

    Console.WriteLine($"Connection string: {cleanCs.Split(';')[0]}");
    Console.WriteLine("Connecting to database to purge and verify all tables...");
    try
    {
        await cleanDb.Database.ExecuteSqlRawAsync(@"
            DELETE FROM [EvidenceImages];
            DELETE FROM [AlertEvents];
            DELETE FROM [MemberAccesses];
            DELETE FROM [AdaptiveZoneRules];
            DELETE FROM [Devices];
            DELETE FROM [Zones];
            DELETE FROM [AdaptiveProfiles];
            DELETE FROM [OtpChallenges];
            DELETE FROM [Users];
        ");
        Console.WriteLine("✅ TOÀN BỘ BẢNG TRONG DATABASE ĐÃ ĐƯỢC LÀM SẠCH VỀ 0 BẢN GHI!");

        var usersCount = await cleanDb.Users.CountAsync();
        var devicesCount = await cleanDb.Devices.CountAsync();
        var alertsCount = await cleanDb.AlertEvents.CountAsync();
        var zonesCount = await cleanDb.Zones.CountAsync();
        var evidenceCount = await cleanDb.EvidenceImages.CountAsync();
        var otpsCount = await cleanDb.OtpChallenges.CountAsync();
        var memberAccessCount = await cleanDb.MemberAccesses.CountAsync();
        var adaptiveProfilesCount = await cleanDb.AdaptiveProfiles.CountAsync();
        var adaptiveRulesCount = await cleanDb.AdaptiveZoneRules.CountAsync();

        Console.WriteLine($"📊 VERIFICATION COUNTS: Users={usersCount}, Devices={devicesCount}, Alerts={alertsCount}, Zones={zonesCount}, EvidenceImages={evidenceCount}, OTPs={otpsCount}, MemberAccess={memberAccessCount}, Profiles={adaptiveProfilesCount}, Rules={adaptiveRulesCount}");
    }
    catch (Exception ex)
    {
        Console.WriteLine($"❌ Error cleaning database: {ex.Message}");
        if (ex.InnerException != null) Console.WriteLine($"   Inner: {ex.InnerException.Message}");
    }
    return;
}

// 0. Hỗ trợ dọn sạch Database bằng lệnh: dotnet run --project backend/SmartGuard.API -- --clean-db
if (args.Contains("--clean-db"))
{
    var rawCs = builder.Configuration.GetConnectionString("DefaultConnection")
        ?? "Server=DESKTOP-IIQVP6N;Database=SmartGuard_Unified_DB;Trusted_Connection=True;TrustServerCertificate=True;";
    var cleanCs = rawCs.Contains("Connect Timeout=", StringComparison.OrdinalIgnoreCase)
        ? rawCs
        : $"{rawCs.TrimEnd(';')};Connect Timeout=30;";
    var optBuilder = new DbContextOptionsBuilder<SmartGuardDbContext>();
    optBuilder.UseSqlServer(cleanCs, sql =>
        sql.EnableRetryOnFailure(maxRetryCount: 3, maxRetryDelay: TimeSpan.FromSeconds(3), errorNumbersToAdd: null));
    using var cleanDb = new SmartGuardDbContext(optBuilder.Options);

    Console.WriteLine("Connecting to Somee MSSQL to purge all tables...");
    await cleanDb.Database.ExecuteSqlRawAsync(@"
        DELETE FROM [EvidenceImages];
        DELETE FROM [AlertEvents];
        DELETE FROM [MemberAccesses];
        DELETE FROM [AdaptiveZoneRules];
        DELETE FROM [Devices];
        DELETE FROM [Zones];
        DELETE FROM [AdaptiveProfiles];
        DELETE FROM [OtpChallenges];
        DELETE FROM [Users];
    ");
    Console.WriteLine("✅ TOÀN BỘ BẢNG TRONG DATABASE ĐÃ ĐƯỢC LÀM SẠCH VỀ 0 BẢN GHI!");
    return;
}

// 1. Cấu hình Database EF Core (SQL Server) với timeout ngắn để tránh treo ứng dụng
var rawConnectionString = builder.Configuration.GetConnectionString("DefaultConnection")
    ?? "Server=DESKTOP-IIQVP6N;Database=SmartGuard_Unified_DB;Trusted_Connection=True;TrustServerCertificate=True;";
var connectionString = rawConnectionString.Contains("Connect Timeout=", StringComparison.OrdinalIgnoreCase)
    ? rawConnectionString
    : $"{rawConnectionString.TrimEnd(';')};Connect Timeout=15;";

builder.Services.AddDbContext<SmartGuardDbContext>(options =>
    options.UseSqlServer(connectionString, sql =>
        sql.EnableRetryOnFailure(maxRetryCount: 2, maxRetryDelay: TimeSpan.FromSeconds(2), errorNumbersToAdd: null)));

// 2. Cấu hình Dependency Injection Services
builder.Services.Configure<TokenOptions>(builder.Configuration.GetSection(TokenOptions.SectionName));
builder.Services.Configure<EmailOptions>(builder.Configuration.GetSection(EmailOptions.SectionName));
builder.Services.Configure<DiscordOptions>(builder.Configuration.GetSection(DiscordOptions.SectionName));

builder.Services.AddSingleton<ITokenService, TokenService>();
builder.Services.AddScoped<IEmailService, EmailService>();
builder.Services.AddScoped<SmartGuard.API.Services.Adaptive.IAdaptiveRuleEngine, SmartGuard.API.Services.Adaptive.AdaptiveRuleEngine>();

// Discord Bot Service (Hosted Background Service + Singleton Interface)
builder.Services.AddSingleton<DiscordBotService>();
builder.Services.AddSingleton<IDiscordAlertService>(sp => sp.GetRequiredService<DiscordBotService>());
builder.Services.AddHostedService(sp => sp.GetRequiredService<DiscordBotService>());

// 3. Cấu hình Rate Limiting (chống brute-force 15 req/min theo IP)
builder.Services.AddRateLimiter(options =>
{
    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.AddPolicy("auth-rate-limit", httpContext =>
        RateLimitPartition.GetFixedWindowLimiter(
            httpContext.Connection.RemoteIpAddress?.ToString() ?? "anonymous",
            _ => new FixedWindowRateLimiterOptions
            {
                PermitLimit = 15,
                Window = TimeSpan.FromMinutes(1),
                QueueLimit = 0
            }));
});

// 4. Cấu hình JWT Authentication
var jwtKey = builder.Configuration["Jwt:Key"] ?? "SmartGuard_Security_Master_Key_2026_AtLeast32BytesLength!";
var jwtIssuer = builder.Configuration["Jwt:Issuer"] ?? "SmartGuardApi";
var jwtAudience = builder.Configuration["Jwt:Audience"] ?? "SmartGuardMobile";

builder.Services.AddAuthentication(options =>
{
    options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
    options.DefaultChallengeScheme = JwtBearerDefaults.AuthenticationScheme;
})
.AddJwtBearer(options =>
{
    options.RequireHttpsMetadata = false;
    options.SaveToken = true;
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuerSigningKey = true,
        IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtKey)),
        ValidateIssuer = true,
        ValidIssuer = jwtIssuer,
        ValidateAudience = true,
        ValidAudience = jwtAudience,
        ValidateLifetime = true,
        ClockSkew = TimeSpan.FromMinutes(1)
    };
});

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("RequireAdmin", policy => policy.RequireRole("Admin"));
    options.AddPolicy("RequireOwnerOrAdmin", policy => policy.RequireRole("Owner", "Admin"));
});

// 5. Cấu hình CORS mở cho thiết bị di động trong mạng LAN
builder.Services.AddCors(options =>
{
    options.AddPolicy("AllowAll", policy =>
    {
        policy.AllowAnyOrigin()
              .AllowAnyMethod()
              .AllowAnyHeader();
    });
});

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();

// 6. Cấu hình Swagger UI có nút Authorize Bearer Token
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "SmartGuard Unified Security API",
        Version = "v1",
        Description = "API giám sát an ninh camera thông minh tích hợp Discord, Sinh trắc học & Adaptive Security"
    });

    c.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
    {
        Description = "Nhập token JWT theo định dạng: Bearer {token}",
        Name = "Authorization",
        In = ParameterLocation.Header,
        Type = SecuritySchemeType.ApiKey,
        Scheme = "Bearer"
    });

    c.AddSecurityRequirement(new OpenApiSecurityRequirement
    {
        {
            new OpenApiSecurityScheme
            {
                Reference = new OpenApiReference
                {
                    Type = ReferenceType.SecurityScheme,
                    Id = "Bearer"
                }
            },
            Array.Empty<string>()
        }
    });
});

var app = builder.Build();

// 7. Khởi tạo / Migrate Database ở luồng nền sau khi Kestrel sẵn sàng (Không nạp dữ liệu mẫu)
app.Lifetime.ApplicationStarted.Register(() =>
{
    _ = Task.Run(async () =>
    {
        using var scope = app.Services.CreateScope();
        var services = scope.ServiceProvider;
        var logger = services.GetRequiredService<ILogger<Program>>();
        var db = services.GetRequiredService<SmartGuardDbContext>();
        try
        {
            await db.Database.MigrateAsync();
            logger.LogInformation("✅ Database migration kiểm tra hoàn tất. Không nạp dữ liệu mẫu.");
        }
        catch (Exception ex)
        {
            logger.LogWarning(ex, "Bỏ qua quá trình seed dữ liệu tự động do giới hạn kết nối hoặc quyền truy cập CSDL.");
        }
    });
});
// 8. Cấu hình HTTP Pipeline
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI(c =>
    {
        c.SwaggerEndpoint("/swagger/v1/swagger.json", "SmartGuard API v1");
        c.RoutePrefix = "swagger";
    });
}

app.UseCors("AllowAll");

// Cho phép load trang chủ index.html mặc định và tài nguyên tĩnh Web Dashboard Capybara Security
app.UseDefaultFiles();
app.UseStaticFiles(new StaticFileOptions
{
    OnPrepareResponse = ctx =>
    {
        var name = ctx.File.Name.ToLowerInvariant();
        if (name.EndsWith(".html") || name.EndsWith(".js") || name.EndsWith(".css"))
        {
            ctx.Context.Response.Headers["Cache-Control"] = "no-cache, no-store, must-revalidate";
            ctx.Context.Response.Headers["Pragma"] = "no-cache";
            ctx.Context.Response.Headers["Expires"] = "0";
        }
    }
}); // Cho phép truy cập ảnh bằng chứng tại /evidence/... và Web Dashboard Capybara Security

app.UseRateLimiter();
app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.MapGet("/api/status", () => Results.Ok(new
{
    service = "SmartGuard Unified Security API - Capybara Edition",
    status = "Online",
    version = "2.5.0-capy",
    docs = "/swagger",
    dbCheckUrl = "/api/status/db"
}));

app.MapGet("/api/status/db", async (SmartGuardDbContext db) =>
{
    var sw = System.Diagnostics.Stopwatch.StartNew();
    try
    {
        var canConnect = await db.Database.CanConnectAsync();
        if (!canConnect)
        {
            return Results.Json(new
            {
                connected = false,
                elapsedMs = sw.ElapsedMilliseconds,
                database = db.Database.GetDbConnection().Database,
                dataSource = db.Database.GetDbConnection().DataSource,
                message = "Không thể kết nối tới SQL Server. Vui lòng kiểm tra chuỗi kết nối (ConnectionString) hoặc mạng Internet."
            }, statusCode: 503);
        }

        var users = await db.Users
            .Select(u => new { u.Id, u.Username, u.Email, u.Role, u.IsLocked })
            .ToListAsync();

        return Results.Ok(new
        {
            connected = true,
            elapsedMs = sw.ElapsedMilliseconds,
            database = db.Database.GetDbConnection().Database,
            dataSource = db.Database.GetDbConnection().DataSource,
            userCount = users.Count,
            users,
            message = "Kết nối Cơ sở dữ liệu (Database) thành công!"
        });
    }
    catch (Exception ex)
    {
        return Results.Json(new
        {
            connected = false,
            elapsedMs = sw.ElapsedMilliseconds,
            database = db.Database.GetDbConnection().Database,
            dataSource = db.Database.GetDbConnection().DataSource,
            error = ex.Message,
            innerError = ex.InnerException?.Message,
            message = $"Lỗi kết nối hoặc truy vấn Database: {ex.InnerException?.Message ?? ex.Message}"
        }, statusCode: 500);
    }
});

app.Run();
