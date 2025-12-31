/**
 * Matomo Tracking - MyProfile (SvelteKit App)
 *
 * Tracks:
 * - Navigation menu clicks
 * - Game page visits
 * - SPA navigation
 * - Interactive element clicks
 */

(function() {
  'use strict';

  if (typeof _paq === 'undefined') {
    console.warn('Matomo not loaded - tracking disabled');
    return;
  }

  // Track SPA navigation (SvelteKit)
  var currentPath = window.location.pathname;

  function trackPageView() {
    var newPath = window.location.pathname;

    if (newPath !== currentPath) {
      currentPath = newPath;

      // Send pageview to Matomo
      _paq.push(['setCustomUrl', window.location.href]);
      _paq.push(['setDocumentTitle', document.title]);
      _paq.push(['trackPageView']);
    }
  }

  // Listen for SvelteKit navigation
  window.addEventListener('popstate', trackPageView);

  // MutationObserver to detect SPA changes
  var observer = new MutationObserver(function() {
    trackPageView();
  });

  observer.observe(document.body, {
    childList: true,
    subtree: true
  });

  // Click tracking
  document.addEventListener('click', function(e) {
    var target = e.target.closest('a, button');
    if (!target) return;

    // Navigation menu clicks
    if (target.closest('nav') || target.classList.contains('nav-link')) {
      var menuItem = target.textContent.trim();
      var destination = target.href ? target.href.split('/').pop() : 'unknown';

      _paq.push(['trackEvent', 'MyProfile', 'Navigation', menuItem, destination]);
    }

    // Game menu clicks
    else if (target.closest('.game-menu') || target.getAttribute('data-game')) {
      var gameName = target.getAttribute('data-game') || target.textContent.trim();

      _paq.push(['trackEvent', 'MyProfile', 'Game Select', gameName]);
    }

    // Photo/Media interactions
    else if (target.closest('.photo-grid') || target.classList.contains('photo-item')) {
      _paq.push(['trackEvent', 'MyProfile', 'Photo', 'View']);
    }

    // Music player controls
    else if (target.closest('.music-player') || target.classList.contains('music-control')) {
      var action = target.getAttribute('data-action') || target.textContent.trim();

      _paq.push(['trackEvent', 'MyProfile', 'Music', action]);
    }

    // Stats page interactions
    else if (window.location.pathname.includes('/stats') && target.classList.contains('stat-card')) {
      var statName = target.querySelector('.stat-name')?.textContent.trim() || 'Unknown';

      _paq.push(['trackEvent', 'MyProfile', 'Stats', statName]);
    }
  });

  // Track game events
  var gameEvents = ['Pinball', 'Mario', 'Pac-Man', 'Flappy Bird'];

  gameEvents.forEach(function(gameName) {
    // Detect if on game page
    if (window.location.pathname.includes(gameName.toLowerCase().replace(' ', '-'))) {
      _paq.push(['trackEvent', 'MyProfile', 'Game Page', gameName + ' Loaded']);
    }
  });

})();
