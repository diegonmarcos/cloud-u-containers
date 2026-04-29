<?php
/**
 * cypht-api/apply.php — main runner
 *
 * Reads configs.json, dispatches to lib/*.php modules, persists with a single
 * Hm_User_Config_DB::save() (one DB UPDATE for all sections).
 *
 * Usage (called from sidecar.sh):
 *   php /tmp/cypht-config/cypht-api/apply.php
 *
 * Exit codes:
 *   0 — success or graceful skip (any non-fatal issue logs to STDERR)
 */
declare(strict_types=1);

namespace CyphtApi;

require_once __DIR__ . '/lib/bootstrap.php';
require_once __DIR__ . '/lib/accounts.php';
require_once __DIR__ . '/lib/profiles.php';
require_once __DIR__ . '/lib/carddav.php';
require_once __DIR__ . '/lib/feeds.php';
require_once __DIR__ . '/lib/settings.php';

$configsPath = __DIR__ . '/configs.json';
if (!\file_exists($configsPath)) {
    \fwrite(STDERR, "[cypht-api] configs.json missing at $configsPath\n");
    exit(0);
}
$configs = \json_decode(\file_get_contents($configsPath), true);
if (!\is_array($configs)) {
    \fwrite(STDERR, "[cypht-api] invalid configs.json\n");
    exit(0);
}

// ── Bootstrap Cypht framework + load user_config ────────────────────
$ctx = bootstrap($configs);
if ($ctx === null) exit(0);

$userConfig    = $ctx['userConfig'];
$primaryEmail  = $ctx['primary']['email'];
$configsDir    = __DIR__;

// ── Apply each section ──────────────────────────────────────────────
// Accounts MUST run before Profiles — ProfilesApi consumes the seeded
// server-id index from AccountsApi::apply's return value.
$accounts = AccountsApi::apply($userConfig, $configs['accounts'] ?? [],  $configsDir);
$profiles = ProfilesApi::apply($userConfig, $configs['profiles'] ?? [],  $accounts);
$carddav  = CardDavApi ::apply($userConfig, $configs['carddav']  ?? [],  $primaryEmail);
$feeds    = FeedsApi   ::apply($userConfig, $configs['feeds']    ?? [],  $configsDir);
$settings = SettingsApi::apply($userConfig, $configs['settings'] ?? []);

// ── Single save() encrypts + persists everything in one DB UPDATE ───
$ok = $userConfig->save($primaryEmail, $ctx['primary']['pass']);
if ($ok === false) {
    \fwrite(STDERR, "[cypht-api] save() failed\n");
    exit(0);
}

// ── Summary ─────────────────────────────────────────────────────────
\fwrite(STDERR, \sprintf(
    "[cypht-api] applied: %d IMAP, %d SMTP, %d JMAP, %d profiles, %d CardDAV, %d feeds, %d settings under %s\n",
    $accounts['imap'], $accounts['smtp'], $accounts['jmap'],
    $profiles['count'], $carddav['count'], $feeds['count'], $settings['count'],
    $primaryEmail
));
if (!empty($accounts['skipped'])) {
    \fwrite(STDERR, "[cypht-api] skipped accounts (placeholder secrets): " . \implode(', ', $accounts['skipped']) . "\n");
}
if (!empty($profiles['missing'])) {
    \fwrite(STDERR, "[cypht-api] skipped profiles (no matching seed account): " . \implode(', ', $profiles['missing']) . "\n");
}
if (!empty($settings['invalid'])) {
    \fwrite(STDERR, "[cypht-api] skipped invalid setting keys: " . \implode(', ', $settings['invalid']) . "\n");
}
exit(0);
