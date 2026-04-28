<?php
/**
 * seed-accounts.php — declarative pre-seed of Cypht's IMAP/SMTP/JMAP backends
 * under the primary user account.
 *
 * Runs inside the cypht container, invoked from seed-accounts.sh AFTER
 * scripts/create_account.php has created the master user. Uses Cypht's OWN
 * Hm_User_Config_DB so encryption stays under the same key Cypht expects on
 * login (the user's plaintext password — see lib/config.php::save()).
 *
 * Data source: /tmp/cypht-config/seed-accounts.json
 * Secrets:     environment variables named in {primary,extras[]}.pass_env,
 *              injected from .secrets at container start.
 *
 * Idempotent: re-runs replace imap_servers / smtp_servers / jmap_servers
 * arrays with the current seed list. The user's master password (which is
 * also the encryption key for hm_user_settings.settings) is required —
 * if the seeder runs with a wrong password, save() will encrypt new data
 * with that password and the user will be locked out of their old data.
 *
 * Bails quietly if cypht install dir or required env vars are missing.
 */
declare(strict_types=1);

$seedJson = '/tmp/cypht-config/seed-accounts.json';
if (!file_exists($seedJson)) {
    fwrite(STDERR, "[seed-accounts.php] seed file missing: $seedJson\n");
    exit(0);
}
$seed = json_decode(file_get_contents($seedJson), true);
if (!is_array($seed) || empty($seed['primary']['email'])) {
    fwrite(STDERR, "[seed-accounts.php] invalid seed JSON\n");
    exit(0);
}

// Cypht install root — image bakes it at /usr/local/share/cypht
define('APP_PATH', '/usr/local/share/cypht/');
define('VENDOR_PATH', APP_PATH . 'vendor/');
define('WEB_ROOT', '');

$autoload = VENDOR_PATH . 'autoload.php';
$framework = APP_PATH . 'lib/framework.php';
if (!file_exists($autoload) || !file_exists($framework)) {
    fwrite(STDERR, "[seed-accounts.php] cypht install tree missing — skipping\n");
    exit(0);
}

require $autoload;
require $framework;

// Bootstrap matches scripts/create_account.php exactly.
$environment = Hm_Environment::getInstance();
$environment->load();
if (!defined('DEBUG_MODE')) {
    define('DEBUG_MODE', false);
}
$config = new Hm_Site_Config_File();
$environment->define_default_constants($config);

if ($config->get('auth_type') !== 'DB') {
    fwrite(STDERR, "[seed-accounts.php] auth_type != DB — skipping\n");
    exit(0);
}

// ── Resolve primary user + password ──────────────────────────────────
$primaryEmail   = $seed['primary']['email'];
$primaryPassEnv = $seed['primary']['pass_env'] ?? 'ME_PASSWORD';
$primaryPass    = getenv($primaryPassEnv) ?: '';
if ($primaryPass === '' || str_starts_with($primaryPass, 'TODO_')) {
    fwrite(STDERR, "[seed-accounts.php] primary pass env $primaryPassEnv missing/placeholder — skipping\n");
    exit(0);
}

// ── Load existing user_settings (or create empty if first run) ────────
$userConfig = new Hm_User_Config_DB($config);
if (!$userConfig->load($primaryEmail, $primaryPass)) {
    fwrite(STDERR, "[seed-accounts.php] WARN: load() returned false for $primaryEmail — settings may be a fresh row\n");
}

// ── Helpers to translate seed-accounts.json → Cypht server arrays ────
function seedImap(array $extra): ?array {
    if (empty($extra['imap']) || !is_array($extra['imap'])) return null;
    $imap = $extra['imap'];
    return [
        'name'   => $extra['name'] ?? $extra['email'],
        'server' => $imap['host'],
        'port'   => (int)($imap['port'] ?? 993),
        'tls'    => ($imap['secure'] ?? 'TLS') !== 'STARTTLS' && ($imap['secure'] ?? '') !== '',
        'hide'   => false,
        'user'   => $extra['login'] ?? $extra['email'],
        'pass'   => $extra['_pass'],
    ];
}
function seedSmtp(array $extra): ?array {
    if (empty($extra['smtp']) || !is_array($extra['smtp'])) return null;
    $smtp = $extra['smtp'];
    return [
        'name'   => $extra['name'] ?? $extra['email'],
        'server' => $smtp['host'],
        'port'   => (int)($smtp['port'] ?? 465),
        'tls'    => ($smtp['secure'] ?? 'SSL') !== 'STARTTLS' && ($smtp['secure'] ?? '') !== '',
        'user'   => $extra['login'] ?? $extra['email'],
        'pass'   => $extra['_pass'],
    ];
}
function seedJmap(array $extra): ?array {
    if (empty($extra['jmap']) || !is_array($extra['jmap'])) return null;
    $jmap = $extra['jmap'];
    $port = $jmap['port'] ?? null;
    $url = $jmap['url'] ?? sprintf('https://%s%s/.well-known/jmap', $jmap['host'], $port ? ":$port" : '');
    return [
        'name'   => $extra['name'] ?? $extra['email'],
        'server' => $url,
        'hide'   => false,
        'type'   => 'jmap',
        'port'   => false,
        'tls'    => false,
        'user'   => $extra['login'] ?? $extra['email'],
        'pass'   => $extra['_pass'],
    ];
}

// ── Build server arrays ──────────────────────────────────────────────
$imapServers = [];
$smtpServers = [];
$jmapServers = [];

// Each extra has its own pass_env; resolve here.
foreach ($seed['extras'] ?? [] as $extra) {
    $passEnv = $extra['pass_env'] ?? '';
    $pass = $passEnv ? (getenv($passEnv) ?: '') : '';
    if ($pass === '' || str_starts_with($pass, 'TODO_')) {
        fwrite(STDERR, "[seed-accounts.php] env $passEnv unset/placeholder — skipping {$extra['email']}\n");
        continue;
    }
    $extra['_pass'] = $pass;

    if ($e = seedImap($extra)) $imapServers[] = $e;
    if ($e = seedSmtp($extra)) $smtpServers[] = $e;
    if ($e = seedJmap($extra)) $jmapServers[] = $e;
}

// ── Apply to user_config + save ──────────────────────────────────────
// Direct config injection — Cypht's web UI calls Hm_IMAP_List::add() but
// that path requires session bootstrap (handlers/output modules). The
// underlying storage is just a keyed array on $config->config[*_servers],
// which is what save() persists to hm_user_settings.settings.
$userConfig->set('imap_servers', $imapServers);
$userConfig->set('smtp_servers', $smtpServers);
if (!empty($jmapServers)) {
    $userConfig->set('jmap_servers', $jmapServers);
}

$ok = $userConfig->save($primaryEmail, $primaryPass);
if ($ok === false) {
    fwrite(STDERR, "[seed-accounts.php] save() failed\n");
    exit(0);
}

fwrite(STDERR, sprintf(
    "[seed-accounts.php] seeded %d IMAP, %d SMTP, %d JMAP backends under %s\n",
    count($imapServers), count($smtpServers), count($jmapServers), $primaryEmail
));
exit(0);
