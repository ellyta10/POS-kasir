/* Shared POS utilities. Kept as a classic script during the incremental refactor. */
(function attachPOSUtils(global) {
  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, ch => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      '"': '&quot;',
      "'": '&#39;'
    }[ch]));
  }

  function loadLocal(key, fallback) {
    try {
      const raw = localStorage.getItem(key);
      if (raw === null) return fallback;
      const parsed = JSON.parse(raw);
      if (parsed === null || parsed === undefined) return fallback;
      if (Array.isArray(fallback) !== Array.isArray(parsed)) return fallback;
      if (typeof fallback === 'object' && typeof parsed !== 'object') return fallback;
      return parsed;
    } catch (error) {
      console.warn('localStorage rusak, memakai nilai bawaan:', key, error);
      return fallback;
    }
  }

  function getLocalString(key) {
    try {
      return localStorage.getItem(key);
    } catch (error) {
      return null;
    }
  }

  function safeLocalSet(key, value) {
    try {
      localStorage.setItem(key, typeof value === 'string' ? value : JSON.stringify(value));
      return true;
    } catch (error) {
      console.warn('Gagal menyimpan ke localStorage:', key, error);
      return false;
    }
  }

  global.POSUtils = Object.freeze({
    escapeHtml,
    loadLocal,
    getLocalString,
    safeLocalSet
  });
})(window);
