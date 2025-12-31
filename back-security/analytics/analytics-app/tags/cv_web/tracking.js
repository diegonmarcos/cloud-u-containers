/**
 * Matomo Tracking - CV Web Version
 *
 * Tracks:
 * - Download button clicks (PDF/DOCX/MD/CSV)
 * - UI control interactions (theme, font, language)
 * - Navigation toggles
 * - View toggles (desktop/mobile)
 * - Section visibility
 */

(function() {
  'use strict';

  if (typeof _paq === 'undefined') {
    console.warn('Matomo not loaded - tracking disabled');
    return;
  }

  // Helper: Detect CV format from button
  function getCVFormat(element) {
    var id = element.id || '';
    var text = element.textContent || '';

    if (id.includes('pdf') || text.toLowerCase().includes('pdf')) return 'PDF';
    if (id.includes('docx') || text.toLowerCase().includes('docx')) return 'DOCX';
    if (id.includes('csv') || text.toLowerCase().includes('csv')) return 'CSV';
    if (id.includes('md') || text.toLowerCase().includes('markdown')) return 'Markdown';

    return 'Unknown';
  }

  // Click tracking
  document.addEventListener('click', function(e) {
    var target = e.target.closest('a, button');
    if (!target) return;

    // CV Download buttons
    if (target.id && target.id.includes('download-') || target.classList.contains('download-btn')) {
      var format = getCVFormat(target);
      var buttonText = target.textContent.trim();

      _paq.push(['trackEvent', 'CV', 'Download', format, buttonText]);
    }

    // Theme toggle
    else if (target.id === 'theme-toggle' || target.classList.contains('theme-toggle')) {
      var theme = document.documentElement.getAttribute('data-theme') || 'default';

      _paq.push(['trackEvent', 'CV UI', 'Theme Toggle', theme]);
    }

    // Font size controls
    else if (target.id && (target.id.includes('font-') || target.classList.contains('font-size'))) {
      var action = target.id.includes('increase') || target.textContent.includes('+') ? 'Increase' : 'Decrease';

      _paq.push(['trackEvent', 'CV UI', 'Font Size', action]);
    }

    // Language toggle
    else if (target.id === 'language-toggle' || target.classList.contains('lang-toggle')) {
      var language = target.textContent.trim() || document.documentElement.getAttribute('lang') || 'en';

      _paq.push(['trackEvent', 'CV UI', 'Language Toggle', language]);
    }

    // Palette cycler
    else if (target.id === 'palette-cycler' || target.classList.contains('palette-toggle')) {
      _paq.push(['trackEvent', 'CV UI', 'Palette Cycle', 'Next Palette']);
    }

    // Terminal theme
    else if (target.id && target.id.includes('terminal') || target.classList.contains('terminal-theme')) {
      _paq.push(['trackEvent', 'CV UI', 'Terminal Theme Toggle', 'Toggled']);
    }

    // Navigation toggle
    else if (target.id === 'nav-toggle' || target.classList.contains('nav-toggle')) {
      var isOpen = target.getAttribute('aria-expanded') === 'true';

      _paq.push(['trackEvent', 'CV UI', 'Navigation', isOpen ? 'Close' : 'Open']);
    }

    // Desktop/Mobile view toggle
    else if (target.classList.contains('view-toggle') || target.id && target.id.includes('view-')) {
      var viewMode = target.textContent.includes('Desktop') ? 'Desktop' : 'Mobile';

      _paq.push(['trackEvent', 'CV UI', 'View Mode', viewMode]);
    }

    // Collapsible section toggles
    else if (target.classList.contains('collapsible-toggle') || target.getAttribute('role') === 'button') {
      var sectionName = target.textContent.trim() || 'Unknown Section';
      var isExpanded = target.getAttribute('aria-expanded') === 'true';

      _paq.push(['trackEvent', 'CV Engagement', 'Section Toggle', sectionName + ' - ' + (isExpanded ? 'Collapse' : 'Expand')]);
    }

    // View source / GitHub link
    else if (target.href && (target.href.includes('github.com') || target.textContent.includes('source'))) {
      _paq.push(['trackEvent', 'CV', 'View Source', 'GitHub']);
    }
  });

  // Track floating button interactions
  document.querySelectorAll('.floating-button, .floating-btn').forEach(function(btn) {
    btn.addEventListener('click', function() {
      var label = this.getAttribute('aria-label') || this.getAttribute('title') || 'Unknown';

      _paq.push(['trackEvent', 'CV UI', 'Floating Button', label]);
    });
  });

})();
