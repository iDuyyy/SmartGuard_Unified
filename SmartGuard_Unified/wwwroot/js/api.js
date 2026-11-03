/**
 * SmartGuard Unified - Capybara Security API Client
 * Connects web dashboard to ASP.NET Core 8 Backend APIs
 */

const SmartGuardApi = (function() {
  const API_BASE = window.location.origin.includes('localhost') || window.location.origin.includes('127.0.0.1')
    ? '' 
    : '';

  // Auth & Token Storage
  function getToken() {
    return localStorage.getItem('smartguard_token');
  }

  function setToken(token) {
    if (token) {
      localStorage.setItem('smartguard_token', token);
    } else {
      localStorage.removeItem('smartguard_token');
    }
  }

  function getUser() {
    try {
      const u = localStorage.getItem('smartguard_user');
      return u ? JSON.parse(u) : null;
    } catch {
      return null;
    }
  }

  function setUser(user) {
    if (user) {
      localStorage.setItem('smartguard_user', JSON.stringify(user));
    } else {
      localStorage.removeItem('smartguard_user');
    }
  }

  // Base Request Wrapper
  async function request(endpoint, options = {}) {
    const url = `${API_BASE}${endpoint}`;
    const headers = options.headers || {};
    
    // Auto-attach JWT Bearer token if available
    const token = getToken();
    if (token && !headers['Authorization']) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    if (!(options.body instanceof FormData) && !headers['Content-Type']) {
      headers['Content-Type'] = 'application/json';
    }

    const config = {
      ...options,
      headers
    };

    try {
      const response = await fetch(url, config);

      if (response.status === 401) {
        console.warn('Unauthorized request to', endpoint);
      }

      const contentType = response.headers.get('content-type');
      let data = null;
      if (contentType && contentType.includes('application/json')) {
        data = await response.json();
      } else {
        data = await response.text();
      }

      if (!response.ok) {
        let errorMsg = data?.message;
        if (!errorMsg && data?.errors && typeof data.errors === 'object') {
          const firstFieldErrors = Object.values(data.errors).flat();
          if (firstFieldErrors.length > 0) errorMsg = firstFieldErrors.join(' ');
        }
        if (!errorMsg) {
          errorMsg = typeof data === 'string' && data.trim() ? data : `API Error (${response.status})`;
        }
        throw new Error(errorMsg);
      }

      return data;
    } catch (err) {
      console.warn(`[API] ${endpoint} fetch issue:`, err.message);
      throw err;
    }
  }

  // API Methods
  return {
    getToken,
    setToken,
    getUser,
    setUser,
    isAuthenticated: () => !!getToken(),
    async checkDbStatus() {
      return await request('/api/status/db');
    },

    // Authentication Endpoints
    async login(identifier, password) {
      return await request('/api/Auth/login', {
        method: 'POST',
        body: JSON.stringify({ identifier, password })
      });
    },

    async verifyOtp(challengeId, code) {
      const res = await request('/api/Auth/verify-otp', {
        method: 'POST',
        body: JSON.stringify({ challengeId, code })
      });
      if (res && res.token) {
        setToken(res.token);
        setUser({
          userId: res.userId,
          email: res.email,
          username: res.username,
          role: res.role
        });
      }
      return res;
    },

    async register(data) {
      return await request('/api/Auth/register', {
        method: 'POST',
        body: JSON.stringify(data)
      });
    },

    async getProfile() {
      return await request('/api/Auth/me');
    },

    logout() {
      setToken(null);
      setUser(null);
    },

    // Devices Endpoints
    async getDevices() {
      return await request('/api/Devices');
    },

    async getDevice(id) {
      return await request(`/api/Devices/${id}`);
    },

    async createDevice(deviceData) {
      return await request('/api/Devices', {
        method: 'POST',
        body: JSON.stringify(deviceData)
      });
    },

    async updateDevice(id, deviceData) {
      return await request(`/api/Devices/${id}`, {
        method: 'PUT',
        body: JSON.stringify(deviceData)
      });
    },

    async toggleArm(id) {
      return await request(`/api/Devices/${id}/toggle-arm`, {
        method: 'PATCH'
      });
    },

    async deleteDevice(id) {
      return await request(`/api/Devices/${id}`, {
        method: 'DELETE'
      });
    },

    async pairDevice(deviceCode) {
      return await request('/api/Devices/pair', {
        method: 'POST',
        body: JSON.stringify(deviceCode)
      });
    },

    // Zones Endpoints
    async getZones() {
      return await request('/api/Zones');
    },

    async createZone(zoneData) {
      return await request('/api/Zones', {
        method: 'POST',
        body: JSON.stringify(zoneData)
      });
    },

    async updateZone(id, zoneData) {
      return await request(`/api/Zones/${id}`, {
        method: 'PUT',
        body: JSON.stringify(zoneData)
      });
    },

    async deleteZone(id) {
      return await request(`/api/Zones/${id}`, {
        method: 'DELETE'
      });
    },

    // Alerts Endpoints
    async getAlertHistory(limit = 50) {
      return await request(`/api/Alerts/history?limit=${limit}`);
    },

    async triggerAlert(alertData) {
      return await request('/api/Alerts/trigger', {
        method: 'POST',
        body: JSON.stringify(alertData)
      });
    },

    async acknowledgeAlert(id, action) {
      return await request(`/api/Alerts/${id}/action`, {
        method: 'POST',
        body: JSON.stringify({ action })
      });
    },

    async getDeviceAlertStatus(deviceId) {
      return await request(`/api/Alerts/device/${deviceId}/status`);
    },

    // Evidence & Images Endpoints
    async getEvidenceList(limit = 40) {
      return await request(`/api/Images/list?limit=${limit}`);
    },

    async uploadEvidence(formData) {
      return await request('/api/Images/upload', {
        method: 'POST',
        body: formData
      });
    },

    async deleteEvidence(id) {
      return await request(`/api/Images/${id}`, {
        method: 'DELETE'
      });
    },

    // Adaptive Security Profiles
    async getAdaptiveProfiles() {
      return await request('/api/AdaptiveSecurity/profiles');
    },

    async activateProfile(profileId) {
      return await request(`/api/AdaptiveSecurity/profiles/${profileId}/activate`, {
        method: 'POST'
      });
    },

    // Admin Stats
    async getDashboardStats() {
      return await request('/api/Admin/stats');
    }
  };
})();

// Export globally
window.SmartGuardApi = SmartGuardApi;
