/**
 * SmartGuard Unified - Capybara Security Dashboard Application Engine
 * Unified visual design, real-time surveillance feed, reactive event handling.
 */

document.addEventListener('DOMContentLoaded', () => {
  // Global State
  const state = {
    currentView: 'dashboard',
    user: null,
    devices: [],
    zones: [],
    alerts: [],
    recordings: [],
    adaptiveProfiles: [],
    activeProfile: 'Home',
    stats: {
      connectedCameras: 2,
      activeCameras: 2,
      motionEventsToday: 7,
      totalRecordings: 24
    },
    filter: {
      eventSeverity: 'all',
      eventCamera: 'all',
      eventStatus: 'all'
    }
  };

  // DOM Elements Cache
  const views = document.querySelectorAll('.view-section');
  const navItems = document.querySelectorAll('.nav-item');
  const sidebar = document.getElementById('appSidebar');
  const sidebarToggleBtn = document.getElementById('sidebarToggleBtn');
  const mobileMenuBtn = document.getElementById('mobileMenuBtn');
  const pageTitle = document.getElementById('currentPageTitle');
  const breadcrumbCurrent = document.getElementById('breadcrumbCurrent');
  const modePillButtons = document.querySelectorAll('.mode-pill-btn');
  const toastContainer = document.getElementById('toastContainer');

  // Initialize
  initApp();

  async function initApp() {
    setupNavigation();
    setupSidebarToggle();
    setupModePills();
    setupModals();
    setupCameraControls();
    setupMotionControls();
    setupSettingsTabs();
    setupAuthForms();

    // Check user session
    checkUserSession();

    // Initialize Camera Controller
    CameraController.init('viewerVideo', 'viewerCanvas', 'viewerSimulatedImg');

    // Fetch Initial Data
    await loadInitialData();

    // Route to hash if present
    const hash = window.location.hash.replace('#', '') || 'dashboard';
    navigateTo(hash);

    // Periodic live sync (every 12 seconds)
    setInterval(() => {
      syncBackgroundData();
    }, 12000);
  }

  // Session Check
  function checkUserSession() {
    const user = SmartGuardApi.getUser();
    state.user = user || {
      username: 'Guardian Admin',
      email: 'admin@smartguard.local',
      role: 'Admin'
    };
    updateUserUI();
  }

  function updateUserUI() {
    const nameEl = document.getElementById('topbarUserName');
    const roleEl = document.getElementById('topbarUserRole');
    if (nameEl) nameEl.textContent = state.user.username;
    if (roleEl) roleEl.textContent = state.user.role;

    // Update Profile view fields
    const pName = document.getElementById('profileUsername');
    const pEmail = document.getElementById('profileEmail');
    const pRole = document.getElementById('profileRole');
    if (pName) pName.textContent = state.user.username;
    if (pEmail) pEmail.textContent = state.user.email;
    if (pRole) pRole.textContent = state.user.role;
  }

  // Navigation Setup
  function setupNavigation() {
    navItems.forEach(item => {
      item.addEventListener('click', (e) => {
        e.preventDefault();
        const targetView = item.getAttribute('data-view');
        if (targetView) {
          navigateTo(targetView);
          if (window.innerWidth <= 768) {
            sidebar.classList.remove('mobile-open');
          }
        }
      });
    });

    window.addEventListener('hashchange', () => {
      const hash = window.location.hash.replace('#', '');
      if (hash) navigateTo(hash);
    });
  }

  function navigateTo(viewId) {
    if (!document.getElementById(`view-${viewId}`)) {
      viewId = 'dashboard';
    }

    state.currentView = viewId;
    window.location.hash = viewId;

    // Switch view sections
    views.forEach(v => v.classList.remove('active'));
    const target = document.getElementById(`view-${viewId}`);
    if (target) target.classList.add('active');

    // Update active nav item
    navItems.forEach(n => {
      if (n.getAttribute('data-view') === viewId) {
        n.classList.add('active');
      } else {
        n.classList.remove('active');
      }
    });

    // Update Topbar Title & Breadcrumbs
    const titleMap = {
      'dashboard': 'Surveillance Dashboard',
      'live-camera': 'Live Camera Surveillance',
      'devices': 'My Camera Devices',
      'motion': 'Motion & Zone Detection',
      'events': 'Security Events & Timeline',
      'recordings': 'Surveillance Recordings',
      'storage': 'Storage & Data Management',
      'settings': 'System Settings',
      'profile': 'User Profile & Credentials',
      'auth': 'Security Guardian Authentication'
    };

    if (pageTitle) pageTitle.textContent = titleMap[viewId] || 'SmartGuard Unified';
    if (breadcrumbCurrent) breadcrumbCurrent.textContent = titleMap[viewId] || 'Dashboard';

    // View-specific setup
    if (viewId === 'live-camera') {
      CameraController.startStream();
    } else {
      if (!state.isStreamingPersistent) {
        // keep running in background if user prefers
      }
    }
  }

  // Sidebar Toggle
  function setupSidebarToggle() {
    if (sidebarToggleBtn) {
      sidebarToggleBtn.addEventListener('click', () => {
        sidebar.classList.toggle('collapsed');
      });
    }

    if (mobileMenuBtn) {
      mobileMenuBtn.addEventListener('click', () => {
        sidebar.classList.toggle('mobile-open');
      });
    }

    // Close on outside click on mobile
    document.addEventListener('click', (e) => {
      if (window.innerWidth <= 768 && sidebar.classList.contains('mobile-open')) {
        if (!sidebar.contains(e.target) && !mobileMenuBtn.contains(e.target)) {
          sidebar.classList.remove('mobile-open');
        }
      }
    });
  }

  // System Mode Pills (Home, Away, Night)
  function setupModePills() {
    modePillButtons.forEach(btn => {
      btn.addEventListener('click', async () => {
        const mode = btn.getAttribute('data-mode');
        modePillButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        state.activeProfile = mode;

        showToast(`Mode switched to [${mode}]`, 'info');

        // Sync with API if profile exists
        try {
          const profile = state.adaptiveProfiles.find(p => p.modeName.toLowerCase() === mode.toLowerCase());
          if (profile && SmartGuardApi.isAuthenticated()) {
            await SmartGuardApi.activateProfile(profile.id);
          }
        } catch (err) {
          console.log('[Mode] Switched locally');
        }
      });
    });
  }

  // Data Loading with Resilient Fallback
  async function loadInitialData() {
    try {
      // 1. Devices
      try {
        const devs = await SmartGuardApi.getDevices();
        if (devs && devs.length > 0) state.devices = devs;
      } catch (err) {
        useDefaultDevices();
      }

      // 2. Zones
      try {
        const z = await SmartGuardApi.getZones();
        if (z && z.length > 0) state.zones = z;
      } catch (err) {
        useDefaultZones();
      }

      // 3. Alerts
      try {
        const a = await SmartGuardApi.getAlertHistory(40);
        if (a && a.length > 0) state.alerts = a;
      } catch (err) {
        useDefaultAlerts();
      }

      // 4. Evidence / Recordings
      try {
        const recs = await SmartGuardApi.getEvidenceList(40);
        if (recs && recs.length > 0) state.recordings = recs;
      } catch (err) {
        useDefaultRecordings();
      }

      // 5. Adaptive Profiles
      try {
        const profs = await SmartGuardApi.getAdaptiveProfiles();
        if (profs && profs.length > 0) state.adaptiveProfiles = profs;
      } catch {}

      // 6. Admin stats
      try {
        const st = await SmartGuardApi.getDashboardStats();
        if (st) {
          state.stats.connectedCameras = st.totalDevices || state.devices.length;
          state.stats.activeCameras = st.activeArmedDevices || state.devices.filter(d => d.isArmed).length;
          state.stats.motionEventsToday = st.totalAlertsToday || 7;
        }
      } catch {}

      // Pass evidence images to CameraController for simulation
      CameraController.setEvidenceImages(state.recordings);

      // Render all views
      renderDashboard();
      renderDevices();
      renderZones();
      renderAlerts();
      renderRecordings();
      renderStorage();

    } catch (err) {
      console.warn('Initial load error:', err);
    }
  }

  async function syncBackgroundData() {
    try {
      if (SmartGuardApi.isAuthenticated()) {
        const [devs, a] = await Promise.allSettled([
          SmartGuardApi.getDevices(),
          SmartGuardApi.getAlertHistory(20)
        ]);

        if (devs.status === 'fulfilled' && devs.value) {
          state.devices = devs.value;
          renderDevices();
        }
        if (a.status === 'fulfilled' && a.value) {
          state.alerts = a.value;
          renderAlerts();
        }
      }
    } catch {}
  }

  // Default Mock Data for Resilience
  function useDefaultDevices() {
    state.devices = [
      {
        id: 'dev-001',
        name: 'Front Porch Camera (Samsung S9)',
        deviceCode: 'CAM-FRONT-88',
        zoneName: 'Front Door',
        isArmed: true,
        noiseThreshold: 45,
        motionThreshold: 60,
        registeredAt: '2026-10-28T09:30:00Z',
        lastSeenAt: new Date().toISOString()
      },
      {
        id: 'dev-002',
        name: 'Living Room Guard (Pixel 4a)',
        deviceCode: 'CAM-LIVING-12',
        zoneName: 'Living Room',
        isArmed: true,
        noiseThreshold: 50,
        motionThreshold: 55,
        registeredAt: '2026-10-28T10:15:00Z',
        lastSeenAt: new Date().toISOString()
      },
      {
        id: 'dev-003',
        name: 'Backyard Watcher (Redmi Note 9)',
        deviceCode: 'CAM-YARD-44',
        zoneName: 'Backyard Garden',
        isArmed: false,
        noiseThreshold: 65,
        motionThreshold: 70,
        registeredAt: '2026-10-29T14:00:00Z',
        lastSeenAt: '2026-10-31T20:15:00Z'
      }
    ];
  }

  function useDefaultZones() {
    state.zones = [
      { id: 'zone-1', name: 'Front Door Entrance', description: 'Main front gate and perimeter pathway', deviceCount: 1 },
      { id: 'zone-2', name: 'Living Room Area', description: 'Central family room and ground corridor', deviceCount: 1 },
      { id: 'zone-3', name: 'Backyard & Garden', description: 'Rear fence, kitchen back door & terrace', deviceCount: 1 }
    ];
  }

  function useDefaultAlerts() {
    state.alerts = [
      {
        id: 'alt-1',
        deviceName: 'Front Porch Camera (Samsung S9)',
        zoneName: 'Front Door',
        triggerReason: 'Face Recognition - Stranger Detected',
        triggerScore: 88,
        severity: 'Danger',
        status: 'Triggered',
        imageUrl: '/images/sticker_system(6).png',
        triggeredAt: new Date(Date.now() - 15 * 60000).toISOString(),
        adaptiveReason: 'Triggered by [Night Mode] at [Front Door Entrance] (Sensitivity x1.5)'
      },
      {
        id: 'alt-2',
        deviceName: 'Living Room Guard (Pixel 4a)',
        zoneName: 'Living Room',
        triggerReason: 'Vibration & Motion Detection',
        triggerScore: 72,
        severity: 'Warning',
        status: 'Confirmed',
        imageUrl: '/images/alter.png',
        triggeredAt: new Date(Date.now() - 48 * 60000).toISOString(),
        adaptiveReason: 'Accelerated vibration detected while armed in [Away Mode]'
      },
      {
        id: 'alt-3',
        deviceName: 'Front Porch Camera (Samsung S9)',
        zoneName: 'Front Door',
        triggerReason: 'Motion Boundary Crossed',
        triggerScore: 65,
        severity: 'Warning',
        status: 'KnownPerson',
        imageUrl: '/images/sticker_system(1).png',
        triggeredAt: new Date(Date.now() - 130 * 60000).toISOString(),
        adaptiveReason: 'Auto-dismissed: Known household resident identified'
      }
    ];
  }

  function useDefaultRecordings() {
    state.recordings = [
      {
        id: 'rec-01',
        fileName: 'front_door_motion_0850.jpg',
        relativeUrl: '/images/sticker_system.png',
        uploadedAt: new Date(Date.now() - 18 * 60000).toISOString(),
        duration: 32,
        sizeMb: 4.2
      },
      {
        id: 'rec-02',
        fileName: 'stranger_detected_0720.jpg',
        relativeUrl: '/images/sticker_system(2).png',
        uploadedAt: new Date(Date.now() - 55 * 60000).toISOString(),
        duration: 45,
        sizeMb: 5.8
      },
      {
        id: 'rec-03',
        fileName: 'backyard_patrol_0450.jpg',
        relativeUrl: '/images/save.png',
        uploadedAt: new Date(Date.now() - 140 * 60000).toISOString(),
        duration: 20,
        sizeMb: 2.7
      },
      {
        id: 'rec-04',
        fileName: 'livingroom_vibration_0120.jpg',
        relativeUrl: '/images/finding.png',
        uploadedAt: new Date(Date.now() - 280 * 60000).toISOString(),
        duration: 60,
        sizeMb: 8.1
      }
    ];
  }

  // ==========================================
  // RENDERING FUNCTIONS
  // ==========================================

  // View 1: Dashboard
  function renderDashboard() {
    // 1. Stats Counter
    const connEl = document.getElementById('statConnected');
    const armedEl = document.getElementById('statArmed');
    const motionEl = document.getElementById('statMotion');
    const recsEl = document.getElementById('statRecordings');

    if (connEl) connEl.textContent = state.devices.length;
    if (armedEl) armedEl.textContent = state.devices.filter(d => d.isArmed).length;
    if (motionEl) motionEl.textContent = state.alerts.length || 7;
    if (recsEl) recsEl.textContent = state.recordings.length || 24;

    // 2. Camera Grid in Dashboard
    const gridEl = document.getElementById('dashboardCameraGrid');
    if (gridEl) {
      if (state.devices.length === 0) {
        gridEl.innerHTML = `
          <div class="empty-state-box" style="grid-column: 1 / -1;">
            <img src="/images/finding.png" class="empty-state-mascot" alt="No Cameras">
            <h4 class="empty-state-title">No cameras connected yet!</h4>
            <p class="empty-state-desc">Transform your old smartphone into a Capybara smart security camera in minutes.</p>
            <button class="btn btn-primary" onclick="window.SmartGuardApp.openAddDeviceModal()">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
              Add First Camera
            </button>
          </div>
        `;
      } else {
        gridEl.innerHTML = state.devices.map((device, idx) => {
          const isOnline = isDeviceOnline(device.lastSeenAt);
          const thumbUrl = state.recordings[idx % (state.recordings.length || 1)]?.relativeUrl || '/images/sticker_system.png';
          return `
            <div class="camera-preview-card">
              <div class="camera-thumb-box">
                <img src="${thumbUrl}" class="camera-thumb-img" alt="${escapeHtml(device.name)}">
                <div class="camera-live-pill">
                  <span class="pulse-dot" style="background-color: ${isOnline ? 'var(--success-green)' : 'var(--secondary-text)'};"></span>
                  ${isOnline ? 'ONLINE' : 'OFFLINE'}
                </div>
                <div class="camera-zone-pill">${escapeHtml(device.zoneName || 'General Zone')}</div>
              </div>
              <div class="camera-card-body">
                <div class="camera-card-title-row">
                  <h4 class="camera-name">${escapeHtml(device.name)}</h4>
                  <span class="badge ${device.isArmed ? 'badge-success' : 'badge-secondary'}">
                    ${device.isArmed ? 'ARMED' : 'DISARMED'}
                  </span>
                </div>
                <p class="camera-meta">Code: <code>${escapeHtml(device.deviceCode || 'N/A')}</code> &bull; Last seen: ${formatDate(device.lastSeenAt)}</p>
                <div class="camera-card-actions">
                  <button class="btn btn-primary btn-sm" style="flex: 1;" onclick="window.SmartGuardApp.viewCamera('${device.id}')">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"></path><circle cx="12" cy="12" r="3"></circle></svg>
                    View Live
                  </button>
                  <button class="btn btn-outline btn-sm" onclick="window.SmartGuardApp.toggleDeviceArm('${device.id}')">
                    ${device.isArmed ? 'Disarm' : 'Arm'}
                  </button>
                </div>
              </div>
            </div>
          `;
        }).join('');
      }
    }

    // 3. Recent Security Activity
    const feedEl = document.getElementById('dashboardActivityFeed');
    if (feedEl) {
      if (state.alerts.length === 0) {
        feedEl.innerHTML = `
          <div class="empty-state-box" style="padding: 24px;">
            <img src="/images/sticker_bao_an.png" class="empty-state-mascot" style="width: 80px; height: 80px;" alt="Peaceful">
            <h4 class="empty-state-title" style="font-size: 1rem;">All Quiet & Safe</h4>
            <p class="empty-state-desc" style="font-size: 0.8rem;">No suspicious security events detected today.</p>
          </div>
        `;
      } else {
        feedEl.innerHTML = state.alerts.slice(0, 5).map(alert => {
          const badgeClass = alert.severity === 'Danger' ? 'badge-danger' : (alert.severity === 'Warning' ? 'badge-warning' : 'badge-info');
          const thumb = alert.imageUrl || '/images/alter.png';
          return `
            <div class="activity-item">
              <img src="${thumb}" class="activity-thumb" alt="Alert">
              <div class="activity-content">
                <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 2px;">
                  <h5 class="activity-title">${escapeHtml(alert.triggerReason)}</h5>
                  <span class="badge ${badgeClass}" style="font-size: 0.68rem;">${alert.severity}</span>
                </div>
                <p class="activity-meta">${escapeHtml(alert.deviceName)} &bull; ${formatTimeAgo(alert.triggeredAt)}</p>
                ${alert.adaptiveReason ? `<p style="font-size: 0.72rem; color: var(--security-blue); margin-top: 4px;">🛡️ ${escapeHtml(alert.adaptiveReason)}</p>` : ''}
              </div>
            </div>
          `;
        }).join('');
      }
    }
  }

  // View 3: Device Management
  function renderDevices() {
    const listEl = document.getElementById('devicesCardsContainer');
    if (!listEl) return;

    if (state.devices.length === 0) {
      listEl.innerHTML = `
        <div class="empty-state-box" style="grid-column: 1 / -1; padding: 60px 20px;">
          <img src="/images/finding.png" class="empty-state-mascot" alt="No Devices">
          <h3 class="empty-state-title">No cameras connected yet!</h3>
          <p class="empty-state-desc">Let's get your first Capybara camera ready. Tap below to pair your smartphone.</p>
          <button class="btn btn-primary" onclick="window.SmartGuardApp.openAddDeviceModal()">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
            Add Camera Device
          </button>
        </div>
      `;
      return;
    }

    listEl.innerHTML = state.devices.map(device => {
      const isOnline = isDeviceOnline(device.lastSeenAt);
      return `
        <div class="device-item-card">
          <div>
            <div class="device-card-header">
              <div class="device-icon-box">
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="5" y="2" width="14" height="20" rx="2" ry="2"></rect><line x1="12" y1="18" x2="12.01" y2="18"></line></svg>
              </div>
              <span class="badge ${isOnline ? 'badge-success' : 'badge-secondary'}">
                <span class="pulse-dot" style="background-color: ${isOnline ? 'var(--success-green)' : 'var(--secondary-text)'};"></span>
                ${isOnline ? 'ONLINE' : 'OFFLINE'}
              </span>
            </div>
            <div class="device-card-body">
              <h4 class="device-name-heading">${escapeHtml(device.name)}</h4>
              <span class="device-code-chip">ID: ${escapeHtml(device.deviceCode || 'N/A')}</span>
              <p style="font-size: 0.82rem; color: var(--secondary-text); margin-bottom: 8px;">
                Zone: <strong>${escapeHtml(device.zoneName || 'Unassigned')}</strong>
              </p>
              <div style="display: flex; gap: 8px; font-size: 0.75rem; color: var(--secondary-text);">
                <span>Motion Sens: <strong>${device.motionThreshold || 60}%</strong></span>
                <span>Noise Sens: <strong>${device.noiseThreshold || 50}%</strong></span>
              </div>
            </div>
          </div>
          <div class="device-card-footer">
            <button class="btn btn-outline btn-sm" onclick="window.SmartGuardApp.toggleDeviceArm('${device.id}')">
              ${device.isArmed ? '🛡️ Armed' : '🔓 Disarmed'}
            </button>
            <div style="display: flex; gap: 6px;">
              <button class="btn btn-outline btn-sm" title="Rename" onclick="window.SmartGuardApp.renameDevice('${device.id}', '${escapeHtml(device.name)}')">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 20h9"></path><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"></path></svg>
              </button>
              <button class="btn btn-danger btn-sm" title="Remove" onclick="window.SmartGuardApp.deleteDevice('${device.id}')">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"></path></svg>
              </button>
            </div>
          </div>
        </div>
      `;
    }).join('');
  }

  // View 4: Zones & Motion Detection
  function renderZones() {
    const zonesListEl = document.getElementById('motionZonesContainer');
    if (!zonesListEl) return;

    zonesListEl.innerHTML = state.zones.map(zone => {
      return `
        <div class="card" style="padding: 18px; margin-bottom: 14px;">
          <div style="display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 8px;">
            <div>
              <h4 style="font-size: 1rem; font-weight: 700; color: var(--primary-navy);">${escapeHtml(zone.name)}</h4>
              <p style="font-size: 0.8rem; color: var(--secondary-text);">${escapeHtml(zone.description || 'No description')}</p>
            </div>
            <span class="badge badge-info">${zone.deviceCount || 1} Camera</span>
          </div>
          <div style="display: flex; align-items: center; justify-content: space-between; padding-top: 10px; border-top: 1px solid var(--border-gray);">
            <div style="display: flex; gap: 12px; font-size: 0.78rem; font-weight: 600; color: var(--security-blue);">
              <span>🔔 Sound: ON</span>
              <span>💬 Discord: ON</span>
            </div>
            <div style="display: flex; gap: 6px;">
              <button class="btn btn-outline btn-sm" onclick="window.SmartGuardApp.editZone('${zone.id}', '${escapeHtml(zone.name)}')">Edit</button>
              <button class="btn btn-outline btn-sm" style="color: var(--danger-red);" onclick="window.SmartGuardApp.deleteZone('${zone.id}')">Delete</button>
            </div>
          </div>
        </div>
      `;
    }).join('');
  }

  // View 5: Security Events Timeline
  function renderAlerts() {
    const listEl = document.getElementById('securityEventsTimeline');
    if (!listEl) return;

    let filtered = [...state.alerts];
    if (state.filter.eventSeverity !== 'all') {
      filtered = filtered.filter(a => a.severity.toLowerCase() === state.filter.eventSeverity.toLowerCase());
    }

    if (filtered.length === 0) {
      listEl.innerHTML = `
        <div class="empty-state-box" style="padding: 60px 20px;">
          <img src="/images/alter.png" class="empty-state-mascot" alt="No Events">
          <h3 class="empty-state-title">No Security Events</h3>
          <p class="empty-state-desc">Your perimeter is quiet and protected under Capybara security patrol.</p>
        </div>
      `;
      return;
    }

    listEl.innerHTML = filtered.map(alert => {
      const badgeClass = alert.severity === 'Danger' ? 'badge-danger' : (alert.severity === 'Warning' ? 'badge-warning' : 'badge-info');
      const thumb = alert.imageUrl || '/images/alter.png';
      return `
        <div class="timeline-event-card">
          <img src="${thumb}" class="event-thumb-preview" alt="Evidence" onclick="window.SmartGuardApp.openMediaModal('${thumb}')">
          <div class="event-content-block">
            <div class="event-headline">
              <span class="badge ${badgeClass}">${alert.severity}</span>
              <h4 class="event-title">${escapeHtml(alert.triggerReason)}</h4>
            </div>
            <p class="event-description">
              Device: <strong>${escapeHtml(alert.deviceName)}</strong> &bull; Zone: <strong>${escapeHtml(alert.zoneName || 'General')}</strong> &bull; Trigger Score: <strong>${alert.triggerScore || 85}/100</strong> &bull; Time: <strong>${formatDate(alert.triggeredAt)}</strong>
            </p>
            ${alert.adaptiveReason ? `<span class="event-adaptive-note">🛡️ ${escapeHtml(alert.adaptiveReason)}</span>` : ''}
          </div>
          <div class="event-actions-block">
            <button class="btn btn-outline btn-sm" title="Mark Known" onclick="window.SmartGuardApp.acknowledgeAlert('${alert.id}', 'known')">
              👤 Known
            </button>
            <button class="btn btn-outline btn-sm" title="Mute" onclick="window.SmartGuardApp.acknowledgeAlert('${alert.id}', 'mute')">
              🔕 Mute
            </button>
            <button class="btn btn-primary btn-sm" title="Confirm Threat" onclick="window.SmartGuardApp.acknowledgeAlert('${alert.id}', 'stranger')">
              🚨 Threat
            </button>
          </div>
        </div>
      `;
    }).join('');
  }

  // View 6: Recordings Gallery
  function renderRecordings() {
    const listEl = document.getElementById('recordingsGridContainer');
    if (!listEl) return;

    if (state.recordings.length === 0) {
      listEl.innerHTML = `
        <div class="empty-state-box" style="grid-column: 1 / -1; padding: 60px 20px;">
          <img src="/images/save.png" class="empty-state-mascot" alt="No Recordings">
          <h3 class="empty-state-title">No recordings saved yet</h3>
          <p class="empty-state-desc">When motion is detected or snapshots are taken, surveillance evidence will appear here.</p>
        </div>
      `;
      return;
    }

    listEl.innerHTML = state.recordings.map(rec => {
      const imgUrl = rec.relativeUrl || '/images/save.png';
      return `
        <div class="recording-card" onclick="window.SmartGuardApp.openMediaModal('${imgUrl}')">
          <div class="recording-thumb-wrapper">
            <img src="${imgUrl}" class="recording-thumb-img" alt="Recording">
            <div class="recording-play-overlay">
              <div class="play-circle-btn">
                <svg width="20" height="20" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg>
              </div>
            </div>
          </div>
          <div class="recording-body">
            <h5 class="recording-title">${escapeHtml(rec.fileName || 'Surveillance Clip')}</h5>
            <div class="recording-meta">
              <span>${formatDate(rec.uploadedAt)}</span>
              <span>${rec.duration ? rec.duration + 's' : 'Evidence'}</span>
            </div>
          </div>
        </div>
      `;
    }).join('');
  }

  // View 7: Storage Management
  function renderStorage() {
    const count = state.recordings.length;
    const estMb = count * 3.8;
    const usedGb = (estMb / 1024 + 1.2).toFixed(1);
    const freeGb = (100 - usedGb).toFixed(1);
    const pct = Math.min(Math.round((usedGb / 100) * 100), 100);

    const usedEl = document.getElementById('storageUsedText');
    const freeEl = document.getElementById('storageFreeText');
    const barEl = document.getElementById('storageUsedBar');

    if (usedEl) usedEl.textContent = `${usedGb} GB Used`;
    if (freeEl) freeEl.textContent = `${freeGb} GB Free (100 GB Total)`;
    if (barEl) barEl.style.width = `${pct}%`;
  }

  // Camera Toolbar Setup
  function setupCameraControls() {
    const btnStream = document.getElementById('btnToggleStream');
    const btnSnapshot = document.getElementById('btnTakeSnapshot');
    const btnRecord = document.getElementById('btnToggleRecord');
    const btnAudio = document.getElementById('btnToggleAudio');
    const btnNight = document.getElementById('btnToggleNight');
    const btnFullscreen = document.getElementById('btnToggleFullscreen');
    const selQuality = document.getElementById('selCameraQuality');
    const viewerCard = document.getElementById('surveillanceViewerCard');

    if (btnStream) {
      btnStream.addEventListener('click', async () => {
        if (CameraController.isStreaming()) {
          CameraController.stopStream();
          btnStream.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg> Start Feed`;
          btnStream.classList.remove('active');
          showToast('Surveillance feed stopped', 'info');
        } else {
          await CameraController.startStream();
          btnStream.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="6" y="4" width="4" height="16"></rect><rect x="14" y="4" width="4" height="16"></rect></svg> Stop Feed`;
          btnStream.classList.add('active');
          showToast('Live surveillance streaming', 'success');
        }
      });
    }

    if (btnSnapshot) {
      btnSnapshot.addEventListener('click', async () => {
        btnSnapshot.disabled = true;
        showToast('Capturing surveillance snapshot...', 'info');
        const snap = await CameraController.takeSnapshot(state.devices[0]?.id);
        btnSnapshot.disabled = false;

        if (snap) {
          showToast('Snapshot captured & saved to Evidence!', 'success');
          // Add to local recordings
          state.recordings.unshift({
            id: 'rec-' + Date.now(),
            fileName: `manual_snapshot_${Date.now()}.jpg`,
            relativeUrl: snap.previewUrl,
            uploadedAt: new Date().toISOString()
          });
          renderRecordings();
        }
      });
    }

    if (btnRecord) {
      btnRecord.addEventListener('click', () => {
        const isNowRecording = CameraController.toggleRecording(
          (timeStr) => {
            btnRecord.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="6" width="12" height="12"></rect></svg> Stop (${timeStr})`;
            btnRecord.classList.add('recording-active');
          },
          (result) => {
            btnRecord.innerHTML = `<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="10"></circle></svg> Record`;
            btnRecord.classList.remove('recording-active');
            showToast(`Recording completed (${result.duration}s)`, 'success');
          }
        );
      });
    }

    if (btnAudio) {
      btnAudio.addEventListener('click', () => {
        const muted = CameraController.toggleAudio();
        btnAudio.classList.toggle('active', !muted);
        showToast(muted ? 'Audio muted' : 'Audio listening enabled', 'info');
      });
    }

    if (btnNight) {
      btnNight.addEventListener('click', () => {
        const night = CameraController.toggleNightVision();
        btnNight.classList.toggle('active', night);
        showToast(night ? 'Night Vision (IR) Active' : 'Normal Daytime Vision', 'info');
      });
    }

    if (btnFullscreen && viewerCard) {
      btnFullscreen.addEventListener('click', () => {
        CameraController.toggleFullscreen(viewerCard);
      });
    }

    if (selQuality) {
      selQuality.addEventListener('change', (e) => {
        CameraController.setQuality(e.target.value);
        showToast(`Resolution switched to ${e.target.value}`, 'info');
      });
    }
  }

  // Motion Detection Slider & Presets
  function setupMotionControls() {
    const slider = document.getElementById('motionSensitivitySlider');
    const valText = document.getElementById('motionSensitivityVal');
    const presets = document.querySelectorAll('.preset-btn');

    if (slider && valText) {
      slider.addEventListener('input', (e) => {
        valText.textContent = `${e.target.value}%`;
      });
    }

    presets.forEach(p => {
      p.addEventListener('click', () => {
        const val = p.getAttribute('data-val');
        presets.forEach(b => b.classList.remove('active'));
        p.classList.add('active');
        if (slider && valText) {
          slider.value = val;
          valText.textContent = `${val}%`;
        }
        showToast(`Sensitivity set to ${val}%`, 'info');
      });
    });
  }

  // Settings Tabs Setup
  function setupSettingsTabs() {
    const tabBtns = document.querySelectorAll('.tab-nav-btn');
    const tabPanes = document.querySelectorAll('.settings-tab-pane');

    tabBtns.forEach(btn => {
      btn.addEventListener('click', () => {
        const tab = btn.getAttribute('data-tab');
        tabBtns.forEach(b => b.classList.remove('active'));
        tabPanes.forEach(p => p.classList.remove('active'));

        btn.classList.add('active');
        const target = document.getElementById(`tab-pane-${tab}`);
        if (target) target.classList.add('active');
      });
    });
  }

  // Auth Forms Setup
  function setupAuthForms() {
    const loginForm = document.getElementById('loginForm');
    const registerForm = document.getElementById('registerForm');
    const btnQuickAdmin = document.getElementById('btnQuickAdminLogin');
    const tabLogin = document.getElementById('authTabLogin');
    const tabRegister = document.getElementById('authTabRegister');
    const footerSwitch = document.getElementById('authFooterSwitch');
    const cardTitle = document.getElementById('authCardTitle');
    const cardSubtitle = document.getElementById('authCardSubtitle');

    function switchAuthMode(mode) {
      const isReg = mode === 'register';
      if (loginForm) loginForm.style.display = isReg ? 'none' : 'block';
      if (registerForm) registerForm.style.display = isReg ? 'block' : 'none';
      if (tabLogin) {
        tabLogin.className = isReg ? 'btn btn-outline btn-sm' : 'btn btn-primary btn-sm';
        if (isReg) tabLogin.style.border = 'none';
      }
      if (tabRegister) {
        tabRegister.className = isReg ? 'btn btn-primary btn-sm' : 'btn btn-outline btn-sm';
        if (!isReg) tabRegister.style.border = 'none';
      }
      if (cardTitle) {
        cardTitle.textContent = isReg ? 'Create Guardian Account' : 'Security Guardian Login';
      }
      if (cardSubtitle) {
        cardSubtitle.textContent = isReg
          ? 'Register a new account to monitor your cameras and receive OTP alerts'
          : 'Authenticate to access smart home camera surveillance';
      }
      if (footerSwitch) {
        footerSwitch.innerHTML = isReg
          ? 'Already have an account? <a href="#auth" id="linkSwitchToLogin" style="font-weight: 700; color: var(--security-blue);">Sign In</a>'
          : 'Don\'t have a camera account? <a href="#auth" id="linkSwitchToRegister" style="font-weight: 700; color: var(--security-blue);">Register New Account</a>';
        const linkReg = document.getElementById('linkSwitchToRegister');
        const linkLog = document.getElementById('linkSwitchToLogin');
        if (linkReg) linkReg.addEventListener('click', (e) => { e.preventDefault(); switchAuthMode('register'); });
        if (linkLog) linkLog.addEventListener('click', (e) => { e.preventDefault(); switchAuthMode('login'); });
      }
    }

    if (tabLogin) tabLogin.addEventListener('click', () => switchAuthMode('login'));
    if (tabRegister) tabRegister.addEventListener('click', () => switchAuthMode('register'));
    const initLinkReg = document.getElementById('linkSwitchToRegister');
    if (initLinkReg) {
      initLinkReg.addEventListener('click', (e) => {
        e.preventDefault();
        switchAuthMode('register');
      });
    }

    if (loginForm) {
      loginForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const iden = document.getElementById('loginIdentifier').value.trim();
        const pass = document.getElementById('loginPassword').value;

        showToast('Authenticating with Capybara Security...', 'info');
        try {
          const res = await SmartGuardApi.login(iden, pass);
          if (res.challengeId) {
            // Open OTP Challenge Modal (pass devOtp if returned for .local or SMTP fallback)
            openOtpModal(res.challengeId, res.email, res.devOtp, res.message);
          } else if (res.token) {
            showToast('Login successful! Welcome Guardian.', 'success');
            checkUserSession();
            navigateTo('dashboard');
          }
        } catch (err) {
          showToast(err.message || 'Login failed. Check credentials.', 'danger');
        }
      });
    }

    if (btnQuickAdmin) {
      btnQuickAdmin.addEventListener('click', () => {
        document.getElementById('loginIdentifier').value = 'admin@smartguard.local';
        document.getElementById('loginPassword').value = 'Admin123@';
        showToast('Default Admin credentials pre-filled!', 'info');
      });
    }

    if (registerForm) {
      registerForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const username = document.getElementById('regUsername').value.trim();
        const email = document.getElementById('regEmail').value.trim();
        const password = document.getElementById('regPassword').value;
        const confirmPassword = document.getElementById('regConfirmPassword')?.value ?? password;

        if (username.length < 3) {
          showToast('Username must be at least 3 characters.', 'warning');
          return;
        }
        if (password.length < 6) {
          showToast('Password must be at least 6 characters.', 'warning');
          return;
        }
        if (password !== confirmPassword) {
          showToast('Passwords do not match.', 'danger');
          return;
        }

        try {
          await SmartGuardApi.register({ email, username, password, role: 'Owner' });
          showToast('Registration successful! You can now sign in.', 'success');
          document.getElementById('loginIdentifier').value = email;
          document.getElementById('loginPassword').value = password;
          switchAuthMode('login');
        } catch (err) {
          showToast(err.message || 'Registration failed.', 'danger');
        }
      });
    }
  }

  // Modals Controller
  function setupModals() {
    const backdrop = document.getElementById('modalBackdrop');
    const closeBtns = document.querySelectorAll('.modal-close-trigger');

    closeBtns.forEach(btn => {
      btn.addEventListener('click', closeModal);
    });

    if (backdrop) {
      backdrop.addEventListener('click', (e) => {
        if (e.target === backdrop) closeModal();
      });
    }
  }

  function openModal(contentHtml) {
    const backdrop = document.getElementById('modalBackdrop');
    const body = document.getElementById('modalDynamicContent');
    if (backdrop && body) {
      body.innerHTML = contentHtml;
      backdrop.classList.add('active');
    }
  }

  function closeModal() {
    const backdrop = document.getElementById('modalBackdrop');
    if (backdrop) backdrop.classList.remove('active');
  }

  function openOtpModal(challengeId, maskedEmail, devOtp, serverMessage) {
    const devBanner = devOtp
      ? `<div style="background: #eff6ff; border: 1px dashed #3b82f6; border-radius: 10px; padding: 10px; margin-bottom: 14px; font-size: 0.85rem; color: #1e3a8a;">
           ⚡ <strong>Mã OTP (Local / Fallback):</strong> <span style="font-family: monospace; font-size: 1.15rem; font-weight: 800; letter-spacing: 3px;">${escapeHtml(devOtp)}</span>
           <div style="font-size: 0.75rem; color: #475569; margin-top: 2px;">Đã tự động điền sẵn mã OTP cho bạn</div>
         </div>`
      : `<div style="font-size: 0.78rem; color: var(--secondary-text); margin-bottom: 12px;">
           💡 Kiểm tra hộp thư đến hoặc mục <strong>Spam / Thư rác</strong> trên Gmail của bạn.
         </div>`;

    openModal(`
      <div style="text-align: center; padding: 10px;">
        <img src="/images/lock.png" style="width: 80px; height: 80px; margin-bottom: 12px;" alt="OTP">
        <h3 style="color: var(--primary-navy); margin-bottom: 6px;">Two-Factor Verification</h3>
        <p style="font-size: 0.88rem; color: var(--secondary-text); margin-bottom: 12px;">
          ${escapeHtml(serverMessage || 'A 6-digit OTP code was sent to')} <strong>${escapeHtml(maskedEmail || 'your email')}</strong>
        </p>
        ${devBanner}
        <div class="form-group">
          <input type="text" id="otpInputCode" class="form-input" value="${devOtp ? escapeHtml(devOtp) : ''}" placeholder="Enter 6-digit code" maxlength="6" style="text-align: center; font-size: 1.4rem; letter-spacing: 6px; font-family: monospace;">
        </div>
        <button class="btn btn-primary btn-lg" style="width: 100%;" onclick="window.SmartGuardApp.submitOtp('${challengeId}')">
          Verify &amp; Access Dashboard
        </button>
      </div>
    `);
  }

  // Toasts
  function showToast(message, type = 'info') {
    if (!toastContainer) return;
    const toast = document.createElement('div');
    toast.className = 'toast';
    
    const iconColor = type === 'success' ? 'var(--success-green)' : (type === 'danger' ? 'var(--danger-red)' : 'var(--security-blue)');
    toast.innerHTML = `
      <div style="width: 10px; height: 10px; border-radius: 50%; background: ${iconColor};"></div>
      <span style="font-size: 0.88rem; font-weight: 600; color: var(--primary-navy);">${escapeHtml(message)}</span>
    `;

    toastContainer.appendChild(toast);
    setTimeout(() => {
      toast.style.opacity = '0';
      toast.style.transform = 'translateX(100%)';
      toast.style.transition = 'all 0.3s ease';
      setTimeout(() => toast.remove(), 300);
    }, 3800);
  }

  // Utilities
  function isDeviceOnline(lastSeen) {
    if (!lastSeen) return false;
    const diffMs = Date.now() - new Date(lastSeen).getTime();
    return diffMs < 120000; // 2 minutes
  }

  function formatDate(isoStr) {
    if (!isoStr) return 'Recently';
    const d = new Date(isoStr);
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  }

  function formatTimeAgo(isoStr) {
    if (!isoStr) return 'Just now';
    const sec = Math.floor((Date.now() - new Date(isoStr).getTime()) / 1000);
    if (sec < 60) return `${sec}s ago`;
    if (sec < 3600) return `${Math.floor(sec / 60)}m ago`;
    return `${Math.floor(sec / 3600)}h ago`;
  }

  function escapeHtml(str) {
    if (!str) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Global App Actions for Inline Handlers
  window.SmartGuardApp = {
    navigateTo,
    switchAuthMode(mode) {
      const isReg = mode === 'register';
      const loginForm = document.getElementById('loginForm');
      const registerForm = document.getElementById('registerForm');
      const tabLogin = document.getElementById('authTabLogin');
      const tabRegister = document.getElementById('authTabRegister');
      const footerSwitch = document.getElementById('authFooterSwitch');
      const cardTitle = document.getElementById('authCardTitle');
      const cardSubtitle = document.getElementById('authCardSubtitle');
      if (loginForm) loginForm.style.display = isReg ? 'none' : 'block';
      if (registerForm) registerForm.style.display = isReg ? 'block' : 'none';
      if (tabLogin) {
        tabLogin.className = isReg ? 'btn btn-outline btn-sm' : 'btn btn-primary btn-sm';
        tabLogin.style.border = isReg ? 'none' : '';
      }
      if (tabRegister) {
        tabRegister.className = isReg ? 'btn btn-primary btn-sm' : 'btn btn-outline btn-sm';
        tabRegister.style.border = !isReg ? 'none' : '';
      }
      if (cardTitle) cardTitle.textContent = isReg ? 'Create Guardian Account' : 'Security Guardian Login';
      if (cardSubtitle) {
        cardSubtitle.textContent = isReg
          ? 'Register a new account to monitor your cameras and receive OTP alerts'
          : 'Authenticate to access smart home camera surveillance';
      }
      if (footerSwitch) {
        footerSwitch.innerHTML = isReg
          ? 'Already have an account? <button type="button" onclick="window.SmartGuardApp.switchAuthMode(\'login\')" style="background: none; border: none; padding: 0; cursor: pointer; font-weight: 700; color: var(--security-blue); font-size: inherit; text-decoration: underline;">Sign In</button>'
          : 'Don\'t have a camera account? <button type="button" onclick="window.SmartGuardApp.switchAuthMode(\'register\')" style="background: none; border: none; padding: 0; cursor: pointer; font-weight: 700; color: var(--security-blue); font-size: inherit; text-decoration: underline;">Register New Account</button>';
      }
    },
    showToast,
    closeModal,

    viewCamera(deviceId) {
      navigateTo('live-camera');
    },

    async toggleDeviceArm(deviceId) {
      try {
        if (SmartGuardApi.isAuthenticated()) {
          await SmartGuardApi.toggleArm(deviceId);
        }
        const dev = state.devices.find(d => d.id === deviceId);
        if (dev) {
          dev.isArmed = !dev.isArmed;
          showToast(`Camera [${dev.name}] ${dev.isArmed ? 'Armed' : 'Disarmed'}`, dev.isArmed ? 'success' : 'warning');
          renderDashboard();
          renderDevices();
        }
      } catch (err) {
        showToast(err.message, 'danger');
      }
    },

    openAddDeviceModal() {
      openModal(`
        <div>
          <div style="display: flex; align-items: center; gap: 12px; margin-bottom: 16px;">
            <img src="/images/finding.png" style="width: 48px; height: 48px; object-fit: contain;" alt="Add Device">
            <div>
              <h3 style="color: var(--primary-navy); margin-bottom: 2px;">Add New Camera Device</h3>
              <p style="font-size: 0.85rem; color: var(--secondary-text);">Connect an old smartphone or IP camera to SmartGuard</p>
            </div>
          </div>
          <div class="form-group">
            <label class="form-label">Camera Device Name</label>
            <input type="text" id="newDevName" class="form-input" placeholder="e.g. Front Gate Guardian">
          </div>
          <div class="form-group">
            <label class="form-label">Zone</label>
            <select id="newDevZone" class="custom-select" style="width: 100%;">
              ${state.zones.map(z => `<option value="${z.id}">${z.name}</option>`).join('')}
            </select>
          </div>
          <div style="display: flex; gap: 14px;">
            <div class="form-group" style="flex: 1;">
              <label class="form-label">Motion Sensitivity (%)</label>
              <input type="number" id="newDevMotion" class="form-input" value="65" min="1" max="100">
            </div>
            <div class="form-group" style="flex: 1;">
              <label class="form-label">Noise Sensitivity (%)</label>
              <input type="number" id="newDevNoise" class="form-input" value="50" min="1" max="100">
            </div>
          </div>
          <div style="display: flex; gap: 10px; margin-top: 14px;">
            <button class="btn btn-outline" style="flex: 1;" onclick="window.SmartGuardApp.closeModal()">Cancel</button>
            <button class="btn btn-primary" style="flex: 2;" onclick="window.SmartGuardApp.submitNewDevice()">Register Camera</button>
          </div>
        </div>
      `);
    },

    async submitNewDevice() {
      const name = document.getElementById('newDevName')?.value;
      const zoneId = document.getElementById('newDevZone')?.value;
      const motion = parseInt(document.getElementById('newDevMotion')?.value || '65');
      const noise = parseInt(document.getElementById('newDevNoise')?.value || '50');

      if (!name) {
        showToast('Please enter a camera name', 'warning');
        return;
      }

      try {
        let newDev = null;
        if (SmartGuardApi.isAuthenticated()) {
          newDev = await SmartGuardApi.createDevice({ name, zoneId, motionThreshold: motion, noiseThreshold: noise });
        } else {
          newDev = {
            id: 'dev-' + Date.now(),
            name,
            deviceCode: 'CAM-' + Math.floor(1000 + Math.random() * 9000),
            zoneName: state.zones.find(z => z.id === zoneId)?.name || 'General',
            isArmed: true,
            motionThreshold: motion,
            noiseThreshold: noise,
            lastSeenAt: new Date().toISOString()
          };
        }

        state.devices.push(newDev);
        closeModal();
        showToast(`Camera [${name}] registered! Pair code: ${newDev.deviceCode || 'CAM-PAIR'}`, 'success');
        renderDashboard();
        renderDevices();
      } catch (err) {
        showToast(err.message, 'danger');
      }
    },

    async renameDevice(id, currentName) {
      const newName = prompt('Enter new camera name:', currentName);
      if (newName && newName.trim() !== '') {
        try {
          if (SmartGuardApi.isAuthenticated()) {
            await SmartGuardApi.updateDevice(id, { name: newName.trim() });
          }
          const dev = state.devices.find(d => d.id === id);
          if (dev) dev.name = newName.trim();
          showToast('Camera renamed', 'success');
          renderDevices();
        } catch (err) {
          showToast(err.message, 'danger');
        }
      }
    },

    async deleteDevice(id) {
      if (confirm('Are you sure you want to remove this camera?')) {
        try {
          if (SmartGuardApi.isAuthenticated()) {
            await SmartGuardApi.deleteDevice(id);
          }
          state.devices = state.devices.filter(d => d.id !== id);
          showToast('Camera removed', 'info');
          renderDashboard();
          renderDevices();
        } catch (err) {
          showToast(err.message, 'danger');
        }
      }
    },

    async acknowledgeAlert(id, action) {
      try {
        if (SmartGuardApi.isAuthenticated()) {
          await SmartGuardApi.acknowledgeAlert(id, action);
        }
        const alt = state.alerts.find(a => a.id === id);
        if (alt) alt.status = action;
        showToast(`Alert updated: ${action}`, 'success');
        renderAlerts();
      } catch (err) {
        showToast(err.message, 'danger');
      }
    },

    openMediaModal(mediaUrl) {
      openModal(`
        <div style="text-align: center;">
          <h4 style="color: var(--primary-navy); margin-bottom: 14px;">Surveillance Evidence Viewer</h4>
          <img src="${mediaUrl}" style="width: 100%; max-height: 520px; object-fit: contain; border-radius: var(--radius-md); background: #000;" alt="Evidence">
          <div style="display: flex; justify-content: flex-end; gap: 10px; margin-top: 14px;">
            <a href="${mediaUrl}" download class="btn btn-outline btn-sm">Download File</a>
            <button class="btn btn-primary btn-sm" onclick="window.SmartGuardApp.closeModal()">Close</button>
          </div>
        </div>
      `);
    },

    async submitOtp(challengeId) {
      const code = document.getElementById('otpInputCode')?.value;
      if (!code || code.length < 6) {
        showToast('Please enter the 6-digit OTP code', 'warning');
        return;
      }

      try {
        await SmartGuardApi.verifyOtp(challengeId, code);
        closeModal();
        showToast('Authentication complete! Welcome.', 'success');
        checkUserSession();
        navigateTo('dashboard');
      } catch (err) {
        showToast(err.message || 'Invalid OTP code', 'danger');
      }
    },

    logout() {
      SmartGuardApi.logout();
      showToast('Logged out of SmartGuard', 'info');
      navigateTo('auth');
    }
  };
});

