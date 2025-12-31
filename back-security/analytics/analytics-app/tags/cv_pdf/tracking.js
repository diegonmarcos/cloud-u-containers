/**
 * Matomo Tracking - CV PDF Viewer
 *
 * Tracks:
 * - Download button clicks (PDF/DOCX/MD/CSV)
 * - PDF page navigation
 * - Zoom controls
 * - Print actions
 */

(function() {
  'use strict';

  if (typeof _paq === 'undefined') {
    console.warn('Matomo not loaded - tracking disabled');
    return;
  }

  // Helper: Get download format
  function getFormat(element) {
    var id = element.id || '';
    var text = element.textContent || '';

    if (id.includes('pdf') || text.toLowerCase().includes('pdf')) return 'PDF';
    if (id.includes('docx') || text.toLowerCase().includes('docx') || text.toLowerCase().includes('word')) return 'DOCX';
    if (id.includes('csv') || text.toLowerCase().includes('csv') || text.toLowerCase().includes('spreadsheet')) return 'CSV';
    if (id.includes('md') || text.toLowerCase().includes('markdown')) return 'Markdown';

    return 'Unknown';
  }

  // Click tracking
  document.addEventListener('click', function(e) {
    var target = e.target.closest('a, button');
    if (!target) return;

    // Download buttons
    if (target.id && target.id.includes('download-') || target.classList.contains('download-btn')) {
      var format = getFormat(target);

      _paq.push(['trackEvent', 'CV PDF', 'Download', format]);
    }

    // Page navigation
    else if (target.id && (target.id.includes('page-') || target.id.includes('nav-'))) {
      var direction = target.id.includes('next') || target.id.includes('forward') ? 'Next Page' : 'Previous Page';

      _paq.push(['trackEvent', 'CV PDF', 'Navigation', direction]);
    }

    // Zoom controls
    else if (target.id && (target.id.includes('zoom') || target.classList.contains('zoom'))) {
      var zoomAction = target.id.includes('in') || target.textContent.includes('+') ? 'Zoom In' : 'Zoom Out';

      _paq.push(['trackEvent', 'CV PDF', 'Zoom', zoomAction]);
    }

    // Print
    else if (target.id === 'print-btn' || target.textContent.toLowerCase().includes('print')) {
      _paq.push(['trackEvent', 'CV PDF', 'Print', 'Initiated']);
    }

    // Full screen toggle
    else if (target.id && target.id.includes('fullscreen')) {
      _paq.push(['trackEvent', 'CV PDF', 'Fullscreen', 'Toggle']);
    }
  });

  // Track PDF viewer loaded
  window.addEventListener('load', function() {
    setTimeout(function() {
      var pdfViewer = document.querySelector('#pdf-viewer, iframe[src*="pdf"], embed[type="application/pdf"]');

      if (pdfViewer) {
        _paq.push(['trackEvent', 'CV PDF', 'Viewer', 'Loaded Successfully']);
      }
    }, 1000);
  });

  // Track print events
  window.addEventListener('beforeprint', function() {
    _paq.push(['trackEvent', 'CV PDF', 'Print', 'Dialog Opened']);
  });

  window.addEventListener('afterprint', function() {
    _paq.push(['trackEvent', 'CV PDF', 'Print', 'Dialog Closed']);
  });

})();
