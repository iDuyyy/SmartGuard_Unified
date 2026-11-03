# 📱 SmartGuard Mobile — Phân Hệ Ứng Dụng Di Động & Edge AI

> Ứng dụng di động thuộc hệ sinh thái **SmartGuard Unified — Capybara Security Edition**, phát triển bằng **Flutter 3.x** kết hợp **Android Native Kotlin (`MethodChannel`)**.

---

## 🌟 Toàn Bộ Chức Năng Hiện Có Trên Ứng Dụng Di Động

### 1. 📞 Danh bạ Người thân Khẩn cấp & Tự động Gọi điện qua SIM thật
- **Files thực thi**: [`lib/services/emergency_service.dart`](lib/services/emergency_service.dart), [`lib/screens/members/members_screen.dart`](lib/screens/members/members_screen.dart), [`lib/services/foreground_service_controller.dart`](lib/services/foreground_service_controller.dart), [`android/.../MainActivity.kt`](android/app/src/main/kotlin/com/smartguard/smartguard_mobile/MainActivity.kt).
- **Quản lý danh bạ người thân (`EmergencyContactModel`)**:
  - Thêm/xóa người thân với đầy đủ thông tin: Họ tên, Số điện thoại, Mối quan hệ (*Chủ nhà, Vợ/Chồng, Bố/Mẹ, Con cái, Anh/Chị/Em, Hàng xóm, Bảo vệ*).
  - Bật/tắt tùy chọn **Tự động gọi điện (`isCallAlert`)** và **Tự động gửi SMS (`isSmsAlert`)** cho từng người.
  - Có sẵn 3 liên hệ mặc định được lưu trữ cục bộ qua `SharedPreferences`.
- **Cơ chế quay số trực tiếp qua SIM (`Intent.ACTION_CALL`)**:
  - Sử dụng kênh giao tiếp Native `MethodChannel('com.smartguard/phone')` kết nối xuống hàm `makePhoneCall()` trong [`MainActivity.kt`](android/app/src/main/kotlin/com/smartguard/smartguard_mobile/MainActivity.kt#L192-L217).
  - Khi phát hiện xâm nhập (qua Camera AI hoặc Cảm biến hợp nhất), `AlertOrchestrator._callEmergencyContacts()` tự động lấy người thân đầu tiên có bật `isCallAlert` và **thực hiện cuộc gọi SIM trực tiếp ngay lập tức** (không dừng ở màn hình chờ bấm nút gọi).
  - Hỗ trợ nút **Thử nghiệm gọi tự động (`Gọi ngay qua SIM`)** ngay trên từng dòng liên hệ trong màn hình **Thành viên**.

### 2. ⚡ Hợp nhất Đa Cảm biến (Sensor Fusion) & Điều phối Báo động (`AlertOrchestrator`)
- **Files thực thi**: [`lib/services/sensor_fusion_service.dart`](lib/services/sensor_fusion_service.dart), [`lib/screens/motion/motion_detection_screen.dart`](lib/screens/motion/motion_detection_screen.dart).
- **Thuật toán Peak-Weighted Synergy**:
  - Kết hợp **Gia tốc kế 3 trục (`40%`)** + **AI Âm thanh YAMNet (`40%`)** + **Nhận diện khuôn mặt (`20%`)** cùng bộ phát hiện đỉnh (`Peak Detection`).
  - Khi `fusedScore >= triggerThreshold` (mặc định `0.65`), `AlertOrchestrator.triggerFullAlert()` tự động kích hoạt đồng bộ 5 tác vụ:
    1. **Rung thiết bị (`Vibration`)** theo chuỗi xung khẩn cấp.
    2. **Phát cảnh báo giọng nói Tiếng Việt (`TtsService`)**.
    3. **Bật thông báo báo động đỏ (`notifyAlarm`)** trên Android Foreground Service.
    4. **Gửi cảnh báo `POST /api/alerts/trigger`** lên máy chủ để bắn tin nhắn sang Discord.
    5. **Gọi điện khẩn cấp qua SIM** tới người thân trong danh bạ.

### 3. 🎙️ Trí tuệ Nhân tạo Phân tích Âm thanh (`YAMNet TFLite`)
- **File thực thi**: [`lib/services/sound_classifier_service.dart`](lib/services/sound_classifier_service.dart).
- Thu âm PCM 16-bit, 16kHz Mono từ microphone, phân tích trên luồng riêng (`IsolateInterpreter`) với 521 lớp âm thanh chuẩn của Google YAMNet:
  - Nhận diện chính xác: **Kính vỡ (`Glass/Shatter`)**, **Tiếng la hét (`Scream`)**, **Tiếng nổ/Súng (`Gunshot/Explosion`)**, **Cạy cửa/Bước chân (`Knock/Slam/Footsteps`)**.
  - Tự động lọc bỏ tiếng nói chuyện bình thường (`Speech`), âm nhạc (`Music`), tiếng mưa gió để chống báo động giả.
  - Có cổng im lặng (`silenceRms = 0.008`) giúp tiết kiệm pin khi phòng yên tĩnh.

### 4. 📷 Giám sát Camera AI, Nhận diện Người quen & Đồng bộ Tắt chuông từ Discord
- **File thực thi**: [`lib/screens/camera/camera_guard_screen.dart`](lib/screens/camera/camera_guard_screen.dart).
- Phát trực tiếp luồng camera trước/sau, tích hợp **Google ML Kit Face Detection**.
- Tự động phân biệt **Người quen** (đã đăng ký trong hệ thống -> đọc lời chào Tiếng Việt và tự tắt báo động) với **Người lạ** (tự động chụp ảnh bằng chứng hiện trường, upload lên `/api/images/upload` và phát báo động).
- **Polling 2 giây (`/api/alerts/device/{id}/status`)**: Khi chủ nhà bấm nút **"✅ Người quen"** hoặc **"🔕 Tắt chuông"** trên Discord, điện thoại tự động dừng còi hú và tạm nghỉ 3 phút (`Snooze`).

### 5. 🛡️ Dịch vụ Chạy ngầm Bền bỉ (`ForegroundService` + `WakeLock` + `BootReceiver`)
- **Files thực thi**: [`SmartGuardForegroundService.kt`](android/app/src/main/kotlin/com/smartguard/smartguard_mobile/SmartGuardForegroundService.kt), [`SmartGuardBootReceiver.kt`](android/app/src/main/kotlin/com/smartguard/smartguard_mobile/SmartGuardBootReceiver.kt), [`battery_exemption_prompt.dart`](lib/widgets/battery_exemption_prompt.dart).
- Giữ tiến trình canh gác hoạt động liên tục khi tắt màn hình (`PARTIAL_WAKE_LOCK`), tự khởi động lại sau 2 giây nếu bị vuốt đóng khỏi đa nhiệm (`onTaskRemoved`) và tự chạy lại khi khởi động lại máy (`BOOT_COMPLETED`).

---

## 📂 Danh Mục Tất Cả Màn Hình Ứng Dụng (`lib/screens/`)

| Màn hình | File mã nguồn | Chức năng chính |
| :--- | :--- | :--- |
| **Welcome & Auth** | [`welcome_screen.dart`](lib/screens/auth/welcome_screen.dart), [`login_screen.dart`](lib/screens/auth/login_screen.dart), [`register_screen.dart`](lib/screens/auth/register_screen.dart), [`otp_screen.dart`](lib/screens/auth/otp_screen.dart) | Đăng nhập, Đăng ký tài khoản, Xác thực mã OTP 6 số 2FA và Mở khóa bằng Vân tay/FaceID. |
| **Home Shell** | [`home_shell.dart`](lib/screens/home_shell.dart) | Khung điều hướng Bottom Navigation Bar kết nối các phân hệ chính. |
| **Dashboard** | [`dashboard_screen.dart`](lib/screens/dashboard/dashboard_screen.dart) | Tổng quan trạng thái an ninh, danh sách thiết bị, bật/tắt cảnh giác nhanh và lối tắt chức năng. |
| **Camera Trực Tiếp** | [`camera_guard_screen.dart`](lib/screens/camera/camera_guard_screen.dart) | Giám sát video trực tiếp, nhận diện khuôn mặt ML Kit, chụp bằng chứng và điều khiển còi báo động. |
| **Cảm Biến & AI Âm Thanh** | [`motion_detection_screen.dart`](lib/screens/motion/motion_detection_screen.dart) | Giám sát gia tốc kế + YAMNet Audio AI, biểu đồ sóng âm thời gian thực và tinh chỉnh ngưỡng nhạy. |
| **An Ninh Thích Ứng** | [`adaptive_security_screen.dart`](lib/screens/adaptive/adaptive_security_screen.dart) | Chuyển đổi 3 chế độ *Ở nhà (Home)*, *Rời nhà (Away)*, *Ban đêm (Night)*, chỉnh quy tắc vùng và *Snooze*. |
| **Khu Vực & Thiết Bị** | [`zones_screen.dart`](lib/screens/zones/zones_screen.dart) | Quản lý phân vùng an ninh, thêm/sửa/xóa thiết bị và ghép nối bằng mã `DeviceCode`. |
| **Thành Viên & Khẩn Cấp** | [`members_screen.dart`](lib/screens/members/members_screen.dart) | Quản lý **Danh bạ người thân khẩn cấp (Gọi SIM/SMS)** và **Chia sẻ tài khoản qua Email**. |
| **Lịch Sử Báo Động** | [`alerts_history_screen.dart`](lib/screens/alerts/alerts_history_screen.dart) | Xem nhật ký cảnh báo, hình ảnh bằng chứng hiện trường và xác nhận/tắt báo động. |
| **Quản Trị Admin** | [`admin_screen.dart`](lib/screens/admin/admin_screen.dart) | Thống kê toàn hệ thống, quản lý người dùng, kho ảnh bằng chứng và danh sách Người quen. |
| **Cài Đặt Hệ Thống** | [`settings_screen.dart`](lib/screens/settings/settings_screen.dart) | Cấu hình & kiểm tra kết nối URL máy chủ (Render/LAN/Emulator), miễn tối ưu pin và đăng xuất. |
