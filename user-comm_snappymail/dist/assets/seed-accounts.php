<?php
/**
 * seed-accounts.php — declarative init-time pre-seed of SnappyMail additional
 * accounts under the primary user.
 *
 * Runs inside the snappymail container (via init.sh). Uses SnappyMail's own
 * Crypt + StorageProvider — no homemade crypto.
 *
 * Data source: /opt/snappymail-config/seed-accounts.json
 * Secrets:     environment variables named in {primary,extras[]}.pass_env,
 *              injected from .secrets at container start.
 *
 * Idempotent: re-runs overwrite the accounts file with the current seed list.
 * Bails quietly if the SnappyMail app tree isn't present (e.g. version bump).
 */
declare(strict_types=1);

$seedJson = '/opt/snappymail-config/seed-accounts.json';
if (!file_exists($seedJson)) {
    fwrite(STDERR, "[seed-accounts] seed file missing: $seedJson\n");
    exit(0);
}
$seed = json_decode(file_get_contents($seedJson), true);
if (!is_array($seed) || empty($seed['primary']['email'])) {
    fwrite(STDERR, "[seed-accounts] invalid seed JSON\n");
    exit(0);
}

// Locate SnappyMail's version dir dynamically (no hardcoded version).
$versions = glob('/snappymail/snappymail/v/*', GLOB_ONLYDIR);
if (!$versions) {
    fwrite(STDERR, "[seed-accounts] SnappyMail app tree not found, skipping\n");
    exit(0);
}
$appRoot = end($versions);
$includeFile = $appRoot . '/include.php';
if (!file_exists($includeFile)) {
    fwrite(STDERR, "[seed-accounts] bootstrap missing: $includeFile\n");
    exit(0);
}

// Minimal CLI-safe bootstrap. include.php wires class loader + constants but
// SnappyMail v2 also auto-serves a request when invoked; swallow that output.
$_SERVER['HTTP_HOST']       = 'localhost';
$_SERVER['SERVER_NAME']     = 'localhost';
$_SERVER['REQUEST_METHOD']  = 'CLI';
$_SERVER['REQUEST_URI']     = '/';
$_SERVER['SCRIPT_FILENAME'] = $includeFile;
chdir($appRoot);
ob_start();
require_once $includeFile;
ob_end_clean();

$primaryEmail = $seed['primary']['email'];
$primaryPassEnv = $seed['primary']['pass_env'] ?? 'ME_PASSWORD';
$primaryPass = getenv($primaryPassEnv);
if (!$primaryPass) {
    fwrite(STDERR, "[seed-accounts] primary pass env $primaryPassEnv not set — skipping\n");
    exit(0);
}

try {
    $actions = \RainLoop\Api::Actions();

    // Synthesize a MainAccount for the primary user, injecting the IMAP pass
    // so CryptKey() can self-initialize.
    $main = new \RainLoop\Model\MainAccount();
    $main->setEmail($primaryEmail);
    $main->setImapUser($primaryEmail);
    $main->setImapPass(new \SnappyMail\SensitiveString($primaryPass));

    $cryptKey = $main->CryptKey();

    $out = [];
    foreach ($seed['extras'] ?? [] as $extra) {
        $pass = getenv($extra['pass_env'] ?? '');
        if (!$pass) {
            fwrite(STDERR, "[seed-accounts] env {$extra['pass_env']} unset — skipping {$extra['email']}\n");
            continue;
        }
        $encPass = \SnappyMail\Crypt::EncryptUrlSafe($pass, $cryptKey);
        $out[$extra['email']] = [
            'email' => $extra['email'],
            'login' => $extra['login'] ?? $extra['email'],
            'pass'  => $encPass,
            'imap'  => $extra['imap'],
            'smtp'  => $extra['smtp'],
            'hmac'  => hash_hmac('sha1', $encPass, $cryptKey),
        ];
    }

    $actions->SetAccounts($main, $out);
    fwrite(STDERR, "[seed-accounts] seeded " . count($out) . " accounts under $primaryEmail\n");
} catch (\Throwable $e) {
    fwrite(STDERR, "[seed-accounts] WARN: seeding failed — " . $e->getMessage() . "\n");
    exit(0);
}
