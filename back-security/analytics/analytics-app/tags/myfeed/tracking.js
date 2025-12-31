/**
 * Matomo Tracking - MyFeed Page
 *
 * Tracks:
 * - Feed item interactions
 * - Filter/sorting actions
 * - Content engagement
 *
 * NOTE: Customize based on actual MyFeed page implementation
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

    // Feed item clicks
    if (target.classList.contains('feed-item') || target.closest('.feed-container')) {
      var itemTitle = target.querySelector('.feed-title')?.textContent.trim() || 'Unknown';

      _paq.push(['trackEvent', 'MyFeed', 'Item Click', itemTitle]);
    }

    // Filter buttons
    else if (target.classList.contains('feed-filter') || target.closest('.filter-controls')) {
      var filterName = target.textContent.trim() || target.getAttribute('data-filter') || 'Unknown';

      _paq.push(['trackEvent', 'MyFeed', 'Filter', filterName]);
    }

    // Sort controls
    else if (target.classList.contains('feed-sort')) {
      var sortType = target.textContent.trim() || target.value || 'Unknown';

      _paq.push(['trackEvent', 'MyFeed', 'Sort', sortType]);
    }
  });

  // Track scroll engagement
  var scrollDepth = 0;

  window.addEventListener('scroll', function() {
    var scrollPercentage = Math.round((window.scrollY / (document.documentElement.scrollHeight - window.innerHeight)) * 100);

    if (scrollPercentage > scrollDepth && scrollPercentage % 25 === 0) {
      scrollDepth = scrollPercentage;
      _paq.push(['trackEvent', 'MyFeed', 'Scroll Depth', scrollPercentage + '%']);
    }
  });

})();
