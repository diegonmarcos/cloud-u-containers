/**
 * Matomo Tracking - Nexus Page
 *
 * Tracks:
 * - Link/navigation clicks
 * - Section interactions
 * - Content engagement
 *
 * NOTE: Customize based on actual Nexus page implementation
 */

(function() {
  'use strict';

  if (typeof _paq === 'undefined') {
    console.warn('Matomo not loaded - tracking disabled');
    return;
  }

  // Generic click tracking
  document.addEventListener('click', function(e) {
    var target = e.target.closest('a, button');
    if (!target) return;

    // Track important interactions
    if (target.classList.contains('nexus-link') || target.closest('.nexus-container')) {
      var linkText = target.textContent.trim();
      var linkUrl = target.href || 'no-url';

      _paq.push(['trackEvent', 'Nexus', 'Link Click', linkText, linkUrl]);
    }
  });

  // Page loaded
  _paq.push(['trackEvent', 'Nexus', 'Page', 'Loaded']);

})();
