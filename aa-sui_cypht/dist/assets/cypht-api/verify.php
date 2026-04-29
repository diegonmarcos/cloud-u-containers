<?php
/**
 * cypht-api/verify.php — runtime read-only verifier
 *
 * Loads user_config the SAME way Cypht does on login (decrypt with the
 * primary password) and runs each module's *_List::init so the state
 * we report is exactly what the Servers/Settings UI would render.
 *
 * Output: KEY=VALUE lines on STDOUT (parseable by the bash tester):
 *   imap_count=N
 *   smtp_count=N
 *   jmap_count=N
 *   feeds_count=N
 *   carddav_count=N
 *   theme_setting=darkly
 *   ...one line per setting key in configs.json#settings...
 *   decrypt_ok=1   # 1 = load() returned true (proves password matches encryption)
 *
 * Usage:
 *   docker exec cypht php /tmp/cypht-config/cypht-api/verify.php
 *
 * Read-only: never calls $userConfig->save().
 */
declare(strict_types=1);

namespace CyphtApi;

require_once __DIR__ . '/lib/bootstrap.php';

$configsPath = __DIR__ . '/configs.json';
$configs = \json_decode(\file_get_contents($configsPath), true);

$ctx = bootstrap($configs);
if ($ctx === null) {
    \fwrite(STDOUT, "decrypt_ok=0\n");
    exit(1);
}
\fwrite(STDOUT, "decrypt_ok=1\n");

$uc           = $ctx['userConfig'];
$primaryEmail = $ctx['primary']['email'];
\fwrite(STDOUT, "primary_email=$primaryEmail\n");

// Use Cypht's own *_List::init so we report what the UI sees.
require_once \APP_PATH . 'modules/imap/hm-imap.php';
require_once \APP_PATH . 'modules/smtp/hm-smtp.php';
require_once \APP_PATH . 'modules/feeds/hm-feed.php';

// Stub session — *_List::init writes session 'user_data' but we don't persist it
$session = new \Hm_PHP_Session($ctx['siteCfg']);
$session->loaded = true;
$session->active = true;
$session->set('username', $primaryEmail);

\Hm_IMAP_List::init($uc, $session);
\Hm_SMTP_List::init($uc, $session);
\Hm_Feed_List::init($uc, $session);

\fwrite(STDOUT, "imap_count="  . \Hm_IMAP_List::count() . "\n");
\fwrite(STDOUT, "smtp_count="  . \Hm_SMTP_List::count() . "\n");
\fwrite(STDOUT, "feeds_count=" . \Hm_Feed_List::count() . "\n");

// JMAP shares Hm_IMAP_List storage but a separate jmap_servers key — read directly.
$jmap = $uc->get('jmap_servers', []);
\fwrite(STDOUT, "jmap_count=" . \count(\is_array($jmap) ? $jmap : []) . "\n");

$cdav = $uc->get('carddav_contacts_auth_setting', []);
\fwrite(STDOUT, "carddav_count=" . \count(\is_array($cdav) ? $cdav : []) . "\n");

// Echo every settings key declared in configs.json (skipping doc keys).
foreach (($configs['settings'] ?? []) as $k => $expected) {
    if (\str_starts_with((string)$k, '_')) continue;
    $actual = $uc->get($k, '<UNSET>');
    if (\is_bool($actual)) $actual = $actual ? 'true' : 'false';
    \fwrite(STDOUT, "$k=$actual\n");
}
exit(0);
