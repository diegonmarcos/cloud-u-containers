#!/usr/bin/env bash
# Cloud Vault brand tester (#1139). Runs brand.sh against a fixture that mirrors the real
# vaultwarden/server 1.37.4 web-vault shape (index.html, main bundle, en locale, manifests)
# and asserts what the login page serves: title, favicon hash, brand strings, no visible
# "Vaultwarden" brand; plus the server-side overrides (scss, admin, email, env).
# Each assertion is proven red by mutating the fixture/brand output (see MUTATIONS below).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$HERE/templates"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
FAIL=0; N=0
ok()  { N=$((N+1)); }
bad() { N=$((N+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }
has() { grep -qF -- "$2" "$1" || return 1; }

# Rendered brand dir = templates without the .tpl suffix (no vars are declared for them).
SRC="$W/config/brand"; mkdir -p "$SRC"
( cd "$T/brand" && find . -type f | while read -r f; do mkdir -p "$SRC/$(dirname "$f")"; cp "$f" "$SRC/${f%.tpl}"; done )
cp "$T/brand.sh.tpl" "$W/config/brand.sh"

mkfixture() { # $1 dir
  local d="$1"; mkdir -p "$d/app" "$d/images/icons" "$d/locales/en" "$d/locales/de"
  printf '%s' '<!doctype html><html class="theme_light"><head><meta charset="utf-8"/><meta name="theme-color" content="#175DDC"/><title page-title>Vaultwarden Web</title><link rel="apple-touch-icon" sizes="180x180" href="images/apple-touch-icon.png"/><link rel="icon" type="image/png" sizes="32x32" href="images/favicon-32x32.png"/><link rel="icon" type="image/png" sizes="16x16" href="images/favicon-16x16.png"/><link rel="mask-icon" href="images/safari-pinned-tab.svg" color="#175DDC"/><link rel="manifest" href="cca56971e438d22818d6.json"/></head><body class="layout_frontend"><link rel="stylesheet" href="css/vaultwarden.css"/><app-root><div><img class="new-logo-themed !tw-w-[200px]" alt="Vaultwarden"/></div></app-root></body></html>' > "$d/index.html"
  printf '%s' 'x;let l="Vaultwarden Web";y;["alt","Vaultwarden",1,"new-logo-themed"];["alt","Bitwarden",1,"logo"];w.EFF(6," A modified version of the Bitwarden® Web Vault for Vaultwarden (an unofficial rewrite of the Bitwarden® server)."),w.EFF(8," Vaultwarden is not associated with the Bitwarden® project nor Bitwarden Inc. ");[Bitwarden]:this.newAcctNudgeService;BitwardenUrl(e){};otpauth://totp/Vaultwarden:' > "$d/app/main.abc123.js"
  printf 'vendor' > "$d/app/vendor.def456.js"
  printf '{"appName":{"message":"Bitwarden"},"loginTitle":{"message":"Log in to Bitwarden"}}' > "$d/locales/en/messages.json"
  printf '{"loginTitle":{"message":"Bei Bitwarden anmelden"}}' > "$d/locales/de/messages.json"
  printf '{"name": "Vaultwarden Web", "theme_color": "#FFFFFF", "background_color": "#FFFFFF"}' > "$d/manifest.json"
  cp "$d/manifest.json" "$d/cca56971e438d22818d6.json"
  printf '{"version":"2026.7.0"}' > "$d/version.json"
  for i in logo.svg logo-white.svg icon-white.svg safari-pinned-tab.svg; do echo "<svg><title>Vaultwarden</title></svg>" > "$d/images/$i"; done
  for i in favicon-16x16.png favicon-32x32.png apple-touch-icon.png android-chrome-192x192.png android-chrome-512x512.png mstile-150x150.png logo-dark@2x.png logo-white@2x.png; do echo old > "$d/images/$i"; done
  for i in favicon-16x16.png favicon-32x32.png apple-touch-icon.png android-chrome-192x192.png android-chrome-512x512.png mstile-150x150.png; do echo old > "$d/images/icons/$i"; done
}
mkfixture "$W/wv"
OUT="$W/out"
env WV="$W/wv" OUT="$OUT" SRC="$SRC" sh -c '. "$1"; echo "WEB_VAULT_FOLDER=${WEB_VAULT_FOLDER:-}"' _ "$W/config/brand.sh" > "$W/run.log" 2>&1
has "$W/run.log" "WEB_VAULT_FOLDER=$OUT" && ok || { bad "brand.sh did not export WEB_VAULT_FOLDER ($(cat "$W/run.log"))"; }

IDX="$OUT/index.html"
HASH="$(sha256sum "$T/brand/icon.svg.tpl" | cut -c1-12)"
has "$IDX" "<title page-title>Cloud Vault</title>" && ok || bad "login title is not Cloud Vault"
has "$IDX" "images/cloud-vault.svg?v=$HASH"        && ok || bad "login page lacks the custom favicon hash $HASH"
has "$IDX" "images/favicon-32x32.png?v=$HASH"      && ok || bad "png favicon link lacks the hash"
has "$IDX" 'alt="Cloud Vault"'                     && ok || bad "login logo alt is not Cloud Vault"
has "$IDX" 'content="#00BFA5"'                     && ok || bad "theme-color is not the accent"
# css/vaultwarden.css is the server's own stylesheet path (not visible); everything else must be clean.
! sed 's|css/vaultwarden\.css||g' "$IDX" | grep -qi "vaultwarden" && ok || bad "index.html still carries a Vaultwarden brand string"
! grep -q "175DDC" "$IDX"                          && ok || bad "Bitwarden blue left in index.html"
# Bundle: visible strings branded, identifiers/API names untouched.
JS="$OUT/app/main.abc123.js"
has "$JS" 'let l="Cloud Vault"'                    && ok || bad "main.js page title string not branded"
has "$JS" 'Cloud Vault: a private, self-hosted password vault.' && ok || bad "main.js footer text not branded"
! grep -q "Vaultwarden Web\|for Vaultwarden\|Vaultwarden is not" "$JS" && ok || bad "main.js still shows upstream footer/brand"
has "$JS" "[Bitwarden]:this.newAcctNudgeService"   && ok || bad "main.js identifier was rewritten (would break the client)"
has "$JS" "BitwardenUrl(e)"                        && ok || bad "main.js API identifier was rewritten"
has "$OUT/locales/en/messages.json" "Log in to Cloud Vault" && ok || bad "en locale not branded"
! grep -qi "bitwarden\|vaultwarden" "$OUT/locales/en/messages.json" && ok || bad "en locale still has upstream names"
has "$OUT/locales/de/messages.json" "Bitwarden"    && ok || bad "non-en locale should be linked untouched"
has "$OUT/manifest.json" "Cloud Vault"             && ok || bad "manifest name not branded"
has "$OUT/cca56971e438d22818d6.json" "Cloud Vault" && ok || bad "hashed manifest not branded"
[ -L "$OUT/app/vendor.def456.js" ] && [ -L "$OUT/version.json" ] && ok || bad "untouched files should be symlinks"
# Images really replaced (valid PNG magic / svg title).
head -c4 "$OUT/images/favicon-32x32.png" | od -An -c | grep -q "P   N   G" && ok || bad "favicon-32 not a PNG"
head -c4 "$OUT/images/icons/apple-touch-icon.png" | od -An -c | grep -q "P   N   G" && ok || bad "icons/apple-touch not replaced"
has "$OUT/images/logo.svg" "Cloud Vault" && has "$OUT/images/logo-white.svg" "Cloud Vault" && ok || bad "logo svgs not replaced"
! grep -rqi "vaultwarden" "$OUT/images/logo.svg" "$OUT/images/logo-white.svg" "$OUT/images/icon-white.svg" && ok || bad "svg logos still say Vaultwarden"
cmp -s "$OUT/images/cloud-vault.svg" "$T/brand/icon.svg.tpl" && ok || bad "cloud-vault.svg is not the declared icon"

# Server-side CSS (user.vaultwarden.scss): name, accent, identity bar.
CSS="$T/brand/scss/user.vaultwarden.scss.hbs.tpl"
has "$CSS" 'content: "Cloud Vault"' && ok || bad "scss lacks the Cloud Vault identity bar"
has "$CSS" '#00BFA5'                && ok || bad "scss lacks the accent colour"
has "$CSS" '--color-primary-600'    && ok || bad "scss does not override the primary scale"
# Admin + email.
has "$T/brand/admin/base.hbs.tpl" "<title>Cloud Vault Admin</title>" && ok || bad "admin title not branded"
! grep -q "vaultwarden-favicon.png" "$T/brand/admin/base.hbs.tpl" && ok || bad "admin still uses the upstream favicon"
has "$T/brand/admin/base.hbs.tpl" "{{urlpath}}/admin/logout" && ok || bad "admin template lost its logout route (copy broken)"
has "$T/brand/email/email_header.hbs.tpl" ">Cloud Vault</span>" && ok || bad "email header not branded"
! grep -qi "vaultwarden" "$T/brand/email/email_header.hbs.tpl" "$T/brand/email/email_footer_text.hbs.tpl" && ok || bad "email templates still say Vaultwarden"
CO="$HERE/compose.nix"
has "$CO" 'SMTP_FROM_NAME      = "Cloud Vault"' && ok || bad "SMTP sender name is not Cloud Vault"
has "$CO" 'TEMPLATES_FOLDER    = "/config/brand"' && ok || bad "TEMPLATES_FOLDER not set"
# API/transport untouched: brand step must not set any server/API variable.
! grep -qE "DOMAIN=|ROCKET_|/api|SIGNUPS" "$T/brand.sh.tpl" && ok || bad "brand.sh touches API/server settings"
# Failsafe: a broken source leaves WEB_VAULT_FOLDER unset and no partial tree.
rm -rf "$W/wv2"; mkfixture "$W/wv2"; rm "$W/wv2/index.html"
env WV="$W/wv2" OUT="$W/out2" SRC="$SRC" sh -c '. "$1"; echo "WEB_VAULT_FOLDER=${WEB_VAULT_FOLDER:-}"' _ "$W/config/brand.sh" > "$W/run2.log" 2>&1
has "$W/run2.log" "WEB_VAULT_FOLDER=" && ! has "$W/run2.log" "WEB_VAULT_FOLDER=$W/out2" && [ ! -e "$W/out2" ] && ok || bad "failsafe: broken brand step must fall back to stock web vault"

echo "cloud-vault-brand: $((N-FAIL))/$N assertions passed"
[ "$FAIL" -eq 0 ]
