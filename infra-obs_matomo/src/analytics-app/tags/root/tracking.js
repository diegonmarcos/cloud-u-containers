/**
 * Matomo Tracking - Root/Landing Page
 *
 * Tracks:
 * - CTA button clicks (Linktree, Portfolio)
 * - Clippy assistant interactions
 * - Theme/animation toggles
 * - Outbound links
 */

(function() {
  'use strict';

  // Wait for Matomo to load
  if (typeof _paq === 'undefined') {
    console.warn('Matomo not loaded - tracking disabled');
    return;
  }

  // Session info on page load
  _paq.push(['trackEvent', 'Session', 'Device Type',
    /Mobile|Android|iPhone|iPad/i.test(navigator.userAgent) ? 'Mobile' : 'Desktop'
  ]);

  // CTA Button Clicks
  document.addEventListener('click', function(e) {
    var target = e.target.closest('a, button');
    if (!target) return;

    // CTA buttons (Linktree, Portfolio, etc.)
    if (target.classList.contains('cta-button') || target.classList.contains('btn-primary')) {
      var buttonText = target.textContent.trim();
      var buttonHref = target.href || target.getAttribute('data-href') || 'no-href';

      _paq.push(['trackEvent', 'CTA', 'Click', buttonText, buttonHref]);
    }

    // Clippy assistant buttons
    if (target.closest('.clippy-controls') || target.classList.contains('clippy-btn')) {
      var action = target.textContent.trim() || target.getAttribute('title') || 'Unknown';

      _paq.push(['trackEvent', 'Clippy', 'Action', action]);
    }

    // Theme toggle
    if (target.id === 'theme-toggle' || target.classList.contains('theme-toggle')) {
      var newTheme = document.documentElement.getAttribute('data-theme') || 'unknown';

      _paq.push(['trackEvent', 'UI', 'Theme Toggle', newTheme]);
    }

    // Animation toggle
    if (target.id === 'animation-toggle' || target.classList.contains('animation-toggle')) {
      var animationState = target.checked ? 'Enabled' : 'Disabled';

      _paq.push(['trackEvent', 'UI', 'Animation Toggle', animationState]);
    }

    // Background toggle
    if (target.id === 'background-toggle' || target.classList.contains('background-toggle')) {
      var bgState = target.checked ? 'Enabled' : 'Disabled';

      _paq.push(['trackEvent', 'UI', 'Background Toggle', bgState]);
    }
  });

  // Track time on page milestones
  var milestones = [10000, 30000, 60000, 120000, 300000]; // 10s, 30s, 1m, 2m, 5m
  var tracked = {};

  milestones.forEach(function(time) {
    setTimeout(function() {
      if (!tracked[time]) {
        tracked[time] = true;
        _paq.push(['trackEvent', 'Engagement', 'Time on Page', (time / 1000) + 's']);
      }
    }, time);
  });

})();
