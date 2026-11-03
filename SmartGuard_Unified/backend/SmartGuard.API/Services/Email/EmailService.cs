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

        public EmailService(IOptions<EmailOptions> smtpSettings, ILogger<EmailService> logger)
        {
            _smtpSettings = smtpSettings.Value;
            _logger = logger;
        }

        public async Task<bool> SendOtpEmailAsync(string toEmail, string username, string otpCode)
        {
            var senderEmail = _smtpSettings.Email?.Trim() ?? string.Empty;
            var appPassword = (_smtpSettings.Password ?? string.Empty).Replace(" ", "");

            if (string.IsNullOrWhiteSpace(senderEmail) || string.IsNullOrWhiteSpace(appPassword))
            {
                _logger.LogWarning("⚠️ [EMAIL] Chưa cấu hình Smtp:Email hoặc Smtp:Password trong appsettings.json. Mã OTP của {Username} là: {OtpCode}", username, otpCode);
                return false;
            }

            var message = new MimeMessage();
            message.From.Add(new MailboxAddress("SmartGuard Security", senderEmail));
            message.To.Add(new MailboxAddress(username, toEmail));
            message.Subject = $"[SmartGuard] Mã xác thực OTP đăng nhập của bạn: {otpCode}";

            var bodyBuilder = new BodyBuilder
            {
                HtmlBody = $@"
                <div style='font-family: Arial, sans-serif; max-width: 520px; margin: 0 auto; padding: 24px; border-radius: 12px; background-color: #0f172a; color: #f8fafc; border: 1px solid #334155;'>
                    <h2 style='color: #38bdf8; margin-top: 0; text-align: center;'>🛡️ SmartGuard Unified Security</h2>
                    <p style='font-size: 15px; color: #e2e8f0;'>Xin chào <strong>{username}</strong>,</p>
                    <p style='font-size: 14px; color: #cbd5e1; line-height: 1.6;'>
                        Hệ thống vừa nhận được yêu cầu đăng nhập vào tài khoản SmartGuard của bạn. Vui lòng nhập mã OTP gồm 6 chữ số dưới đây để hoàn tất xác thực 2 lớp (2FA):
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

            // Thử gửi qua cổng cấu hình (587 StartTls) rồi fallback sang 465 SslOnConnect
            var attempts = new (int Port, SecureSocketOptions Option)[]
            {
                (_smtpSettings.Port, SecureSocketOptions.StartTls),
                (465, SecureSocketOptions.SslOnConnect)
            };

            foreach (var attempt in attempts)
            {
                try
                {
                    using var client = new SmtpClient();
                    client.Timeout = 4500;
                    using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(4500));

                    await client.ConnectAsync(_smtpSettings.Host, attempt.Port, attempt.Option, cts.Token);
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

            _logger.LogWarning("⚠️ [EMAIL] Máy chủ Cloud chặn cổng SMTP 587/465. Sử dụng mã OTP dự phòng ({OtpCode}) cho {ToEmail}.", otpCode, toEmail);
            return false;
        }
    }
}
