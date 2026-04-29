<?php
/**
 * cypht-api/lib/bootstrap.php
 *
 * Loads the Cypht framework so the rest of the API can use Hm_User_Config_DB
 * and friends. Mirrors the bootstrap done by Cypht's own scripts/create_account.php.
 *
 * Returns: an associative array with framework objects ready to use.
 *   [
 *     'siteCfg'    => Hm_Site_Config_File,
 *     'userConfig' => Hm_User_Config_DB (already loaded for primary user),
 *     'primary'    => ['email' => string, 'pass' => string]
 *   ]
 *
 * Bails (returns null) on any non-fatal error so the caller can exit 0 and
 * cypht's normal entrypoint still starts.
 */
declare(strict_types=1);

namespace CyphtApi;

function bootstrap(array $configs): ?array {
    $appPath = '/usr/local/share/cypht/';
    $autoload = $appPath . 'vendor/autoload.php';
    $framework = $appPath . 'lib/framework.php';

    if (!\file_exists($autoload) || !\file_exists($framework)) {
        \fwrite(STDERR, "[cypht-api] cypht install tree missing — skipping\n");
        return null;
    }

    if (!\defined('APP_PATH'))    \define('APP_PATH', $appPath);
    if (!\defined('VENDOR_PATH')) \define('VENDOR_PATH', $appPath . 'vendor/');
    if (!\defined('WEB_ROOT'))    \define('WEB_ROOT', '');

    require_once $autoload;
    require_once $framework;

    $env = \Hm_Environment::getInstance();
    $env->load();
    if (!\defined('DEBUG_MODE')) \define('DEBUG_MODE', false);

    $siteCfg = new \Hm_Site_Config_File();
    $env->define_default_constants($siteCfg);

    if ($siteCfg->get('auth_type') !== 'DB') {
        \fwrite(STDERR, "[cypht-api] auth_type != DB — skipping\n");
        return null;
    }

    // Resolve primary user — declarative pull from configs.json
    $primaryEmail = $configs['primary_user']['email'] ?? '';
    $passEnv      = $configs['primary_user']['pass_env'] ?? 'ME_PASSWORD';
    $primaryPass  = \getenv($passEnv) ?: '';
    if ($primaryEmail === '' || $primaryPass === '' || \str_starts_with($primaryPass, 'TODO_')) {
        \fwrite(STDERR, "[cypht-api] primary_user.email='$primaryEmail' or env $passEnv unset/placeholder — skipping\n");
        return null;
    }

    $userConfig = new \Hm_User_Config_DB($siteCfg);
    if (!$userConfig->load($primaryEmail, $primaryPass)) {
        \fwrite(STDERR, "[cypht-api] WARN: load() returned false for $primaryEmail — fresh settings row\n");
    }

    return [
        'siteCfg'    => $siteCfg,
        'userConfig' => $userConfig,
        'primary'    => ['email' => $primaryEmail, 'pass' => $primaryPass],
    ];
}

/**
 * Wrap an entity in the shape Cypht's Hm_Repository expects.
 * Generates uniqid() (matches lib/repository.php:30), sets entity['id']
 * = array key (lib/repository.php:52), adds object/connected (lib/servers.php:194).
 */
function repoEntity(array $entity): array {
    $id = \uniqid();
    $entity['id']        = $id;
    $entity['object']    = false;
    $entity['connected'] = false;
    return [$id, $entity];
}

/**
 * Resolve a string template with {token} placeholders.
 * Tokens supported by all modules:
 *   {user_url_encoded} → rawurlencode of the primary email
 *   {topic}            → rawurlencode of a feed topic
 *   anything else      → left as-is
 */
function resolveTemplate(string $tpl, array $vars): string {
    $out = $tpl;
    foreach ($vars as $k => $v) {
        $out = \str_replace('{' . $k . '}', \rawurlencode($v), $out);
    }
    return $out;
}

/**
 * Resolve a value-or-env reference. If the configs entry has 'pass_env',
 * read it from getenv(). The special value 'PRIMARY_EMAIL' for user_env
 * resolves to the primary email passed in.
 */
function resolveEnv(string $envName, string $primaryEmail = ''): string {
    if ($envName === 'PRIMARY_EMAIL') return $primaryEmail;
    return \getenv($envName) ?: '';
}
