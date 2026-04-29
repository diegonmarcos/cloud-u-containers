<?php
/**
 * seed-accounts.php — declarative pre-seed of Cypht's user_config:
 *   - 6 mail accounts (IMAP/SMTP/JMAP)
 *   - 1 CardDAV source (Radicale)
 *   - 18 RSS feeds (ntfy topics)
 *   - 9 UI settings (theme=darkly, sieve, snooze, HTML compose, etc.)
 *
 * Runs inside the cypht container, invoked from seed-accounts.sh AFTER
 * scripts/create_account.php has created the master user. Uses Cypht's OWN
 * Hm_User_Config_DB so encryption stays under the same key Cypht expects on
 * login (the user's plaintext password — see lib/config.php::save()).
 *
 * Storage shape (CRITICAL — matches Hm_Repository::add() in lib/repository.php):
 *   imap_servers / smtp_servers / jmap_servers / feeds = uniqid-keyed dict,
 *   each entity has 'id' field equal to its array key, plus 'object'=>false
 *   and 'connected'=>false (added by Hm_Server_List::add at lib/servers.php:194).
 *   Flat integer-keyed lists trigger migrateFromIntegerIds, which only updates
 *   session, not the DB blob → UI sees fresh-empty state every request.
 *
 * Data sources (mounted at /tmp/cypht-config/, within PHP open_basedir):
 *   seed-accounts.json — primary + extras with imap/smtp/jmap host/port/login/pass_env
 *   seed-config.json   — carddav source, feeds source ref, settings block
 *   ntfy-topics.json   — canonical 18 topic list (sourced from
 *                        I_cloud-data/ntfy-api/src/topics.json at flake build time)
 *
 * Idempotent: re-runs replace the lists with the current seed.
 *
 * Bails quietly with exit 0 on any non-fatal error so cypht's web entrypoint
 * still starts.
 */
declare(strict_types=1);

const CONFIG_DIR = '/tmp/cypht-config';

// ── Load seed-accounts.json ──────────────────────────────────────────
$seedJson = CONFIG_DIR . '/seed-accounts.json';
if (!file_exists($seedJson)) {
    fwrite(STDERR, "[seed-accounts.php] seed file missing: $seedJson\n");
    exit(0);
}
$seed = json_decode(file_get_contents($seedJson), true);
if (!is_array($seed) || empty($seed['primary']['email'])) {
    fwrite(STDERR, "[seed-accounts.php] invalid seed JSON\n");
    exit(0);
}

// ── Load seed-config.json (CardDAV + feeds source + UI settings) ─────
$seedConfigPath = CONFIG_DIR . '/seed-config.json';
$seedConfig = [];
if (file_exists($seedConfigPath)) {
    $seedConfig = json_decode(file_get_contents($seedConfigPath), true) ?: [];
} else {
    fwrite(STDERR, "[seed-accounts.php] seed-config.json missing — skipping CardDAV/feeds/settings\n");
}

// ── Cypht install root — image bakes it at /usr/local/share/cypht ────
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
$cyphtCfg = new Hm_Site_Config_File();
$environment->define_default_constants($cyphtCfg);

if ($cyphtCfg->get('auth_type') !== 'DB') {
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
$userConfig = new Hm_User_Config_DB($cyphtCfg);
if (!$userConfig->load($primaryEmail, $primaryPass)) {
    fwrite(STDERR, "[seed-accounts.php] WARN: load() returned false for $primaryEmail — fresh settings row\n");
}

// ── Helpers ──────────────────────────────────────────────────────────

/**
 * Wrap an entity in the shape Cypht's Hm_Repository expects:
 *   - generates uniqid() matching lib/repository.php:30
 *   - sets entity['id'] equal to the array key (lib/repository.php:52)
 *   - adds object=false, connected=false (lib/servers.php:194-195)
 *
 * Returns [id, entity] tuple; caller does $list[$id] = $entity.
 */
function repoEntity(array $entity): array {
    $id = uniqid();
    $entity['id']        = $id;
    $entity['object']    = false;
    $entity['connected'] = false;
    return [$id, $entity];
}

function seedImap(array $extra): ?array {
    if (empty($extra['imap']) || !is_array($extra['imap'])) return null;
    $imap = $extra['imap'];
    $secure = $imap['secure'] ?? 'TLS';
    return [
        'name'   => $extra['name'] ?? $extra['email'],
        'server' => $imap['host'],
        'port'   => (int)($imap['port'] ?? 993),
        'tls'    => $secure !== 'STARTTLS' && $secure !== '',
        'hide'   => false,
        'user'   => $extra['login'] ?? $extra['email'],
        'pass'   => $extra['_pass'],
    ];
}
function seedSmtp(array $extra): ?array {
    if (empty($extra['smtp']) || !is_array($extra['smtp'])) return null;
    $smtp = $extra['smtp'];
    $secure = $smtp['secure'] ?? 'SSL';
    return [
        'name'   => $extra['name'] ?? $extra['email'],
        'server' => $smtp['host'],
        'port'   => (int)($smtp['port'] ?? 465),
        'tls'    => $secure !== 'STARTTLS' && $secure !== '',
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

// ── Build mail-server arrays (uniqid-keyed dict, NOT flat list) ──────
$imapServers = [];
$smtpServers = [];
$jmapServers = [];
$skippedExtras = [];

foreach ($seed['extras'] ?? [] as $extra) {
    $passEnv = $extra['pass_env'] ?? '';
    $pass = $passEnv ? (getenv($passEnv) ?: '') : '';
    if ($pass === '' || str_starts_with($pass, 'TODO_')) {
        fwrite(STDERR, "[seed-accounts.php] env $passEnv unset/placeholder — skipping {$extra['email']}\n");
        $skippedExtras[] = $extra['email'];
        continue;
    }
    $extra['_pass'] = $pass;

    if ($e = seedImap($extra)) { [$id, $ent] = repoEntity($e); $imapServers[$id] = $ent; }
    if ($e = seedSmtp($extra)) { [$id, $ent] = repoEntity($e); $smtpServers[$id] = $ent; }
    if ($e = seedJmap($extra)) { [$id, $ent] = repoEntity($e); $jmapServers[$id] = $ent; }
}

$userConfig->set('imap_servers', $imapServers);
$userConfig->set('smtp_servers', $smtpServers);
if (!empty($jmapServers)) {
    $userConfig->set('jmap_servers', $jmapServers);
}

// ── CardDAV (Radicale) — named-source dict per modules/carddav_contacts/modules.php:28 ──
$cardDavSeeded = 0;
foreach (($seedConfig['carddav'] ?? []) as $sourceName => $cd) {
    $passEnv = $cd['pass_env'] ?? '';
    $pass = $passEnv ? (getenv($passEnv) ?: '') : '';
    if ($pass === '' || str_starts_with($pass, 'TODO_')) {
        fwrite(STDERR, "[seed-accounts.php] CardDAV $sourceName: env $passEnv unset — skipping\n");
        continue;
    }
    // user_env may resolve to PRIMARY_EMAIL (special) or any env var
    $userEnv = $cd['user_env'] ?? 'PRIMARY_EMAIL';
    $user = ($userEnv === 'PRIMARY_EMAIL') ? $primaryEmail : (getenv($userEnv) ?: '');
    if ($user === '') {
        fwrite(STDERR, "[seed-accounts.php] CardDAV $sourceName: user unresolved — skipping\n");
        continue;
    }
    // Build server URL from template (replace {user_url_encoded})
    $tpl = $cd['server_template'] ?? '';
    $server = str_replace('{user_url_encoded}', rawurlencode($user), $tpl);
    if ($server === '') {
        fwrite(STDERR, "[seed-accounts.php] CardDAV $sourceName: server_template empty — skipping\n");
        continue;
    }
    // Hm_User_Config_DB merges into existing carddav_contacts_auth_setting on save.
    $existing = $userConfig->get('carddav_contacts_auth_setting', []);
    if (!is_array($existing)) $existing = [];
    $existing[$sourceName] = ['server' => $server, 'user' => $user, 'pass' => $pass];
    $userConfig->set('carddav_contacts_auth_setting', $existing);
    $cardDavSeeded++;
}

// ── Feeds (ntfy RSS topics) — Hm_Feed_List shape, same uniqid-dict trait ──
$feedsSeeded = 0;
$feedsList = [];
$feedsSpec = $seedConfig['feeds'] ?? null;
if ($feedsSpec && ($feedsSpec['source'] ?? '') === 'ntfy_topics_json') {
    $topicsPath = CONFIG_DIR . '/ntfy-topics.json';
    if (file_exists($topicsPath)) {
        $topicsDoc = json_decode(file_get_contents($topicsPath), true);
        // topics.json shape: {"topics": ["all", "dev_commits", ...]} OR a bare array
        $topics = $topicsDoc['topics'] ?? (is_array($topicsDoc) ? $topicsDoc : []);
        $tpl = $feedsSpec['url_template'] ?? '';
        foreach ($topics as $topic) {
            if (!is_string($topic)) continue;
            $url = str_replace('{topic}', rawurlencode($topic), $tpl);
            [$id, $ent] = repoEntity([
                'name'   => $topic,
                'server' => $url,
                'tls'    => true,
                'port'   => 443,
            ]);
            $feedsList[$id] = $ent;
        }
        $feedsSeeded = count($feedsList);
        $userConfig->set('feeds', $feedsList);
    } else {
        fwrite(STDERR, "[seed-accounts.php] ntfy-topics.json missing at $topicsPath — skipping feeds\n");
    }
}

// ── UI settings — scalar key/value writes ─────────────────────────────
$settingsSeeded = 0;
foreach (($seedConfig['settings'] ?? []) as $key => $value) {
    // Defensive: Cypht uses *_setting suffix convention
    if (!is_string($key) || !str_ends_with($key, '_setting')) {
        fwrite(STDERR, "[seed-accounts.php] skipping setting key '$key' (does not end in _setting)\n");
        continue;
    }
    $userConfig->set($key, $value);
    $settingsSeeded++;
}

// ── Single save() — encrypts + persists in one DB UPDATE ─────────────
$ok = $userConfig->save($primaryEmail, $primaryPass);
if ($ok === false) {
    fwrite(STDERR, "[seed-accounts.php] save() failed\n");
    exit(0);
}

fwrite(STDERR, sprintf(
    "[seed-accounts.php] seeded: %d IMAP, %d SMTP, %d JMAP, %d CardDAV, %d feeds, %d settings under %s\n",
    count($imapServers), count($smtpServers), count($jmapServers),
    $cardDavSeeded, $feedsSeeded, $settingsSeeded, $primaryEmail
));
if (!empty($skippedExtras)) {
    fwrite(STDERR, "[seed-accounts.php] skipped extras (placeholder secrets): " . implode(', ', $skippedExtras) . "\n");
}
exit(0);
