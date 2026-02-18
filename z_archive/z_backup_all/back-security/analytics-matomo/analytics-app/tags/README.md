# Matomo Tracking Tags

Page-specific tracking scripts for Matomo Tag Manager integration.

---

## 📂 Structure

```
tags/
├── README.md                    # This file
├── root/                        # Root/landing page (index.html)
│   └── tracking.js
├── linktree/                    # Linktree page
│   └── tracking.js
├── nexus/                       # Nexus page
│   └── tracking.js
├── cv_pdf/                      # CV PDF viewer
│   └── tracking.js
├── cv_web/                      # CV Web version
│   └── tracking.js
├── myfeed/                      # My Feed page
│   └── tracking.js
├── myprofile/                   # My Profile page
│   └── tracking.js
├── cloud/                       # Cloud/infrastructure page
│   └── tracking.js
└── feed_yourself/               # Feed Yourself page
    └── tracking.js
```

---

## 🎯 Purpose

These scripts provide **page-specific tracking** for Matomo analytics:
- Custom event tracking
- Enhanced data layer
- Page-specific interactions
- Supplement Matomo Tag Manager (MTM) container

---

## 📋 Base Tracking (All Pages)

All pages should include Matomo Tag Manager container:

```html
<!-- Matomo Tag Manager -->
<script>
var _mtm = window._mtm = window._mtm || [];
_mtm.push({'mtm.startTime': (new Date().getTime()), 'event': 'mtm.Start'});
(function() {
  var d=document, g=d.createElement('script'), s=d.getElementsByTagName('script')[0];
  g.async=true; g.src='https://analytics.diegonmarcos.com/js/container_62tfw1ai.js';
  s.parentNode.insertBefore(g,s);
})();
</script>
<!-- End Matomo Tag Manager -->
```

---

## 🏷️ Event Types (from GTM Config)

### Universal Events (All Pages)
- **Page View**: Automatic via MTM
- **Scroll Depth**: 25%, 50%, 75%, 100%
- **Outbound Links**: External link clicks
- **File Downloads**: PDF, DOCX, CSV, etc.
- **Session Info**: Device, browser, viewport

### Page-Specific Events

**Linktree**:
- `linktree_link_click` - Link categories and subsections
- `social_icon_click` - Social media icons

**CV Pages** (pdf/web):
- `cv_download` - Download button clicks (PDF/DOCX/CSV/MD)

**Universal** (if video present):
- `video_interaction` - Play, pause, complete

---

## 🔧 Usage

### Option 1: Include in HTML (Recommended)

```html
<!-- After Matomo Tag Manager container -->
<script src="/matomo/tags/linktree/tracking.js"></script>
```

### Option 2: Inline Script

Copy contents of `tracking.js` into `<script>` tags in page

---

## 📊 Tracked Events Summary

| Page | Custom Events | Built-in Tracking |
|------|---------------|-------------------|
| **root** | CTA clicks, Clippy actions | Scroll, outbound links |
| **linktree** | Link clicks, social icons, vCard | Scroll, file downloads |
| **nexus** | TBD | Scroll, outbound links |
| **cv_pdf** | Download buttons, format selection | Scroll, file downloads |
| **cv_web** | Download buttons, UI controls | Scroll, file downloads |
| **myfeed** | TBD | Scroll, outbound links |
| **myprofile** | Navigation, game interactions | Scroll, outbound links |
| **cloud** | TBD | Scroll, outbound links |
| **feed_yourself** | TBD | Scroll, outbound links |

---

## 🔍 Data Layer Variables

### Standard Variables (GTM-based)

Available on all pages:
- `Page URL`, `Page Hostname`, `Page Path`
- `Page Title`, `Referrer`
- `Click Element`, `Click URL`, `Click Text`
- `Scroll Depth Threshold`
- `Device Type` (mobile/desktop)

### Custom Variables (per page)

**Linktree**:
- `Linktree Link Category` - Section title
- `Linktree Link Subsection` - Subsection name
- `CV Format` - PDF/DOCX/CSV/MD

**CV Pages**:
- `CV Format` - Download format clicked

---

## 🎨 GTM Configuration Reference

Based on `GTM-TN9SV57D.json`:

**Container**: GTM-TN9SV57D
**GA4 ID**: G-VB9ENP6DZ0 (legacy - migrated to Matomo)
**Matomo Container**: 62tfw1ai (current)

**Tags Created** (9):
1. GA4 Config - All Pages
2. GA4 Event - Scroll Depth
3. GA4 Event - Outbound Link
4. GA4 Event - File Download
5. Session Info Tracking
6. Video Tracking - Universal
7. GA4 Event - Linktree Link Click
8. GA4 Event - Social Icon Click
9. GA4 Event - CV Download

**Triggers** (12):
- Scroll Depth (25%, 50%, 75%, 100%)
- Outbound Link Click
- File Download Click
- Timers (10s, 30s, 60s, 120s, 300s)
- Linktree - Link Click
- Linktree - Social Icon Click
- CV - Download Button Click
- All Pages (pageview)

---

## 🚀 Migration Notes

**From GA4 to Matomo**:
- Replace `dataLayer.push()` with `_paq.push()`
- Event structure: `_paq.push(['trackEvent', 'Category', 'Action', 'Name'])`
- Custom dimensions via custom variables in Matomo

**Example Conversion**:

GTM/GA4:
```javascript
dataLayer.push({
  'event': 'linktree_link_click',
  'link_category': 'Professional',
  'link_text': 'GitHub'
});
```

Matomo:
```javascript
_paq.push(['trackEvent', 'Linktree', 'Link Click', 'GitHub']);
```

---

## 📚 Related Documentation

- **Main Matomo Spec**: [`../MATOMO_COMPLETE_SPEC.md`](../../MATOMO_COMPLETE_SPEC.md)
- **Matomo Tag Manager**: https://matomo.org/guide/tag-manager/
- **Matomo Event Tracking**: https://developer.matomo.org/guides/tracking-javascript-guide

---

**Last Updated**: 2025-11-25
**Matomo Container**: 62tfw1ai v6 "Proxy Tracking"
**Tracking Endpoint**: collect.php (anti-blocker)
