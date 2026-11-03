using MailKit.Net.Smtp;
using MailKit.Security;
using Microsoft.Extensions.Options;
using MimeKit;

namespace SmartGuard.API.Services.Email
{
    public class EmailOptions
    {
        public const string SectionName = "Smtp";

        public string Email { get; set; } = string.Empty;
        public string Password { get; set; } = string.Empty;
        public string Host { get; set; } = "smtp.gmail.com";
        public int Port { get; set; } = 587;
        public bool EnableSsl { get; set; } = true;
    }

    public interface IEmailService
    {
        Task<bool> SendOtpEmailAsync(string toEmail, string username, string otpCode);
    }

    public class EmailService : IEmailService
    {
        private readonly EmailOptions _smtpSettings;
        private readonly ILogger<EmailService> _logger;

        private const string DefaultSenderEmail = "uyencao.cs@gmail.com";
        private const string DefaultAppPassword = "cnjaxcgttcovxqpw";

        public EmailService(IOptions<EmailOptions> smtpSettings, ILogger<EmailService> logger)
        {
            _smtpSettings = smtpSettings.Value;
            _logger = logger;
        }

        public async Task<bool> SendOtpEmailAsync(string toEmail, string username, string otpCode)
        {
            var senderEmail = !string.IsNullOrWhiteSpace(_smtpSettings.Email)
                ? _smtpSettings.Email.Trim()
                : (Environment.GetEnvironmentVariable("SMTP_EMAIL")
                   ?? Environment.GetEnvironmentVariable("Smtp__Email")
                   ?? DefaultSenderEmail);

            var rawPassword = !string.IsNullOrWhiteSpace(_smtpSettings.Password)
                ? _smtpSettings.Password
                : (Environment.GetEnvironmentVariable("SMTP_PASSWORD")
                   ?? Environment.GetEnvironmentVariable("Smtp__Password")
                   ?? DefaultAppPassword);

            var appPassword = rawPassword.Replace(" ", "").Trim();

            var host = !string.IsNullOrWhiteSpace(_smtpSettings.Host) ? _smtpSettings.Host.Trim() : "smtp.gmail.com";
            var configuredPort = _smtpSettings.Port > 0 ? _smtpSettings.Port : 587;

            var safeUsername = string.IsNullOrWhiteSpace(username) ? toEmail : username.Trim();

            var message = new MimeMessage();
            message.From.Add(new MailboxAddress("SmartGuard Security", senderEmail));
            message.To.Add(new MailboxAddress(safeUsername, toEmail.Trim()));
            message.Subject = $"[SmartGuard] Mã xác thực OTP đăng nhập của bạn: {otpCode}";

            var bodyBuilder = new BodyBuilder
            {
                HtmlBody = $@"
                <div style='font-family: Arial, sans-serif; max-width: 520px; margin: 0 auto; padding: 24px; border-radius: 12px; background-color: #0f172a; color: #f8fafc; border: 1px solid #334155;'>
                    <h2 style='color: #38bdf8; margin-top: 0; text-align: center;'>🛡️ SmartGuard Unified Security</h2>
                    <p style='font-size: 15px; color: #e2e8f0;'>Xin chào <strong>{safeUsername}</strong>,</p>
                    <p style='font-size: 14px; color: #cbd5e1; line-height: 1.6;'>
                        Hệ thống vừa nhận được yêu cầu đăng nhập vào tài khoản SmartGuard của bạn ({toEmail}). Vui lòng nhập mã OTP gồm 6 chữ số dưới đây để hoàn tất xác thực 2 lớp (2FA):
                    </p>
                    <div style='margin: 24px 0; padding: 18px; background-color: #1e293b; border-radius: 10px; text-align: center; border: 1px dashed #38bdf8;'>
                        <span style='font-size: 32px; font-weight: bold; letter-spacing: 8px; color: #38bdf8;'>{otpCode}</span>
                    </div>
                    <p style='font-size: 13px; color: #94a3b8;'>
                        ⏳ Mã OTP này có hiệu lực trong vòng <strong>5 phút</strong>. Tuyệt đối không chia sẻ mã này cho bất kỳ ai.
                    </p>
                    <hr style='border: none; border-top: 1px solid #334155; margin: 20px 0;' />
                    <p style='font-size: 12px; color: #64748b; text-align: center; margin-bottom: 0;'>
                        Email tự động từ Hệ thống An ninh Thông minh SmartGuard Unified.
                    </p>
                </div>"
            };

            message.Body = bodyBuilder.ToMessageBody();

            // Thử cổng cấu hình (587 StartTls), sau đó fallback sang 465 (SslOnConnect)
            var attempts = new (int Port, SecureSocketOptions Option)[]
            {
                (configuredPort, SecureSocketOptions.StartTls),
                (465, SecureSocketOptions.SslOnConnect)
            };

            foreach (var attempt in attempts)
            {
                try
                {
                    using var client = new SmtpClient();
                    client.Timeout = 6000;
                    using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(6000));

                    await client.ConnectAsync(host, attempt.Port, attempt.Option, cts.Token);
                    await client.AuthenticateAsync(senderEmail, appPassword, cts.Token);
                    await client.SendAsync(message, cts.Token);
                    await client.DisconnectAsync(true, cts.Token);

                    _logger.LogInformation("✅ [EMAIL] Đã gửi mã OTP ({OtpCode}) tới Gmail: {ToEmail} qua cổng {Port}", otpCode, toEmail, attempt.Port);
                    return true;
                }
                catch (Exception ex)
                {
                    _logger.LogWarning("⚠️ [EMAIL] Cổng SMTP {Port} không phản hồi ({Msg}).", attempt.Port, ex.Message);
                }
            }

            _logger.LogWarning("⚠️ [EMAIL] Không thể kết nối cổng SMTP của Gmail (có thể bị chặn bởi tường lửa Cloud Render). Trả về mã OTP dự phòng cho {ToEmail}.", toEmail);
            return false;
        }
    }
}
