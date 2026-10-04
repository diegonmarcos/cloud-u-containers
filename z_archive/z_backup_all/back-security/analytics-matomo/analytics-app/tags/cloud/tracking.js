/**
 * Matomo Tracking - Cloud/Infrastructure Page
 *
 * Tracks:
 * - Service card clicks
 * - Documentation links
 * - Status checks
 *
 * NOTE: Customize based on actual Cloud page implementation
 */

(function() {
  'use strict';

  if (typeof _paq === 'undefined') {
    console.warn('Matomo not loaded - tracking disabled');
    return;
  }

  // Click tracking
  document.addEventListener('click', function(e) {
    var target = e.target.closest('a, button');
    if (!target) return;

    // Service cards
    if (target.classList.contains('service-card') || target.closest('.services-grid')) {
      var serviceName = target.querySelector('.service-name')?.textContent.trim() ||
                       target.getAttribute('data-service') ||
                       target.textContent.trim();

      _paq.push(['trackEvent', 'Cloud', 'Service Click', serviceName]);
    }

    // Documentation links
    else if (target.href && target.href.includes('README.md') || target.textContent.includes('docs')) {
      var docType = target.getAttribute('data-doc-type') || 'General';

      _paq.push(['trackEvent', 'Cloud', 'Documentation', docType]);
    }

    // Status indicators
    else if (target.classList.contains('status-btn') || target.getAttribute('data-status')) {
      var service = target.closest('[data-service]')?.getAttribute('data-service') || 'Unknown';

      _paq.push(['trackEvent', 'Cloud', 'Status Check', service]);
    }
  });

  // Track which services are visible
  window.addEventListener('load', function() {
    var services = document.querySelectorAll('[data-service]');

    if (services.length > 0) {
      _paq.push(['trackEvent', 'Cloud', 'Services Loaded', services.length.toString()]);
    }
  });

})();
