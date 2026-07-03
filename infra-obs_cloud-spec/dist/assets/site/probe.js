// Probe: fetch /probe/<svc>/reach for each .probe div and paint a live badge.
document.addEventListener('DOMContentLoaded', function() {
  document.querySelectorAll('.probe[data-svc]').forEach(function(el) {
    var svc = el.getAttribute('data-svc');
    var badge = el.querySelector('.probe-status');
    if (!badge || !svc) return;
    fetch('/probe/' + svc + '/reach', { credentials: 'same-origin' })
      .then(function(r) { return r.ok ? r.json() : { reachable: false, status: r.status }; })
      .then(function(d) {
        badge.textContent = d.reachable ? ('✓ ' + (d.status || 'up')) : '✗ down';
        badge.style.cssText = 'font-weight:bold;color:' + (d.reachable ? '#4caf50' : '#f44336');
      })
      .catch(function() {
        badge.textContent = '? unreachable';
        badge.style.cssText = 'font-weight:bold;color:#9e9e9e';
      });
  });
});
