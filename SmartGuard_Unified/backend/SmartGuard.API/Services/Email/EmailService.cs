using MailKit.Net.Smtp;
using MimeKit;

namespace SmartGuard.API.Services.Email
{
    public interface IEmailService
    {
        Task<bool> SendOtpEmailAsync(string toEmail, string otpCode, string purpose);
    }

    public class EmailOptions
    {
        public const string SectionName = "Smtp";

        public string Host { get; set; } = string.Empty;
        public int Port { get; set; } = 587;
        public string Email { get; set; } = string.Empty;
        public string Password { get; set; } = string.Empty;
        public bool EnableSsl { get; set; } = true;

        public bool IsConfigured => !string.IsNullOrWhiteSpace(Host) && !string.IsNullOrWhiteSpace(Email) && !string.IsNullOrWhiteSpace(Password);
    }

    public class EmailService : IEmailService
    {
        private readonly EmailOptions _options;
        private readonly ILogger<EmailService> _logger;
        private readonly IHostEnvironment _env;

        public EmailService(
            Microsoft.Extensions.Options.IOptions<EmailOptions> options,
            ILogger<EmailService> logger,
            IHostEnvironment env)
        {
            _options = options.Value;
            _logger = logger;
            _env = env;
        }

        public async Task<bool> SendOtpEmailAsync(string toEmail, string otpCode, string purpose)
        {
            // Tài khoản nội bộ (.local) hoặc chưa cấu hình SMTP → in trực tiếp ra log và trả về devOtp trên giao diện
            if (!_options.IsConfigured || toEmail.EndsWith(".local", StringComparison.OrdinalIgnoreCase))
            {
                _logger.LogWarning("⚠️ [DEV/LOCAL OTP] Mã OTP cho {Email} [{Purpose}] là: >>> {Code} <<< (Hạn 5 phút)",
                    toEmail, purpose, otpCode);
                return false;
            }

            try
            {
                var message = new MimeMessage();
                message.From.Add(new MailboxAddress("SmartGuard Security", _options.Email.Trim()));
                message.To.Add(new MailboxAddress(toEmail, toEmail.Trim()));
                message.Subject = $"[SmartGuard] Mã xác thực {purpose} của bạn: {otpCode}";

                var bodyBuilder = new BodyBuilder
                {
                    HtmlBody = $@"
                        <div style='font-family: Arial, sans-serif; padding: 20px; background: #f8fafc; border-radius: 8px;'>
                            <h2 style='color: #1e3a8a;'>Hệ Thống An Ninh SmartGuard</h2>
                            <p>Bạn vừa yêu cầu mã xác thực cho mục đích: <strong>{purpose}</strong></p>
                            <div style='font-size: 32px; font-weight: bold; color: #2563eb; letter-spacing: 6px; padding: 15px 0;'>
                                {otpCode}
                            </div>
                            <p style='color: #64748b; font-size: 13px;'>Mã này có hiệu lực trong vòng 5 phút. Vui lòng không chia sẻ mã này cho bất kỳ ai.</p>
                        </div>"
                };

                message.Body = bodyBuilder.ToMessageBody();

                using var client = new SmtpClient
                {
                    Timeout = 10000,
                    CheckCertificateRevocation = false,
                    ServerCertificateValidationCallback = (_, _, _, _) => true
                };

                var cleanPassword = _options.Password.Replace(" ", string.Empty).Trim();
                await client.ConnectAsync(_options.Host.Trim(), _options.Port, MailKit.Security.SecureSocketOptions.StartTls);
                await client.AuthenticateAsync(_options.Email.Trim(), cleanPassword);
                await client.SendAsync(message);
                await client.DisconnectAsync(true);

                _logger.LogInformation("✅ Đã gửi email OTP tới {Email}", toEmail);
                return true;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "⚠️ Không gửi được email OTP tới {Email}. Mã OTP dự phòng: >>> {Code} <<<", toEmail, otpCode);
                return false;
            }
        }
    }
}
