<?php
/**
 * cypht-api/lib/accounts.php
 *
 * Apply IMAP / SMTP / JMAP server entries to a Cypht user_config.
 * Source: seed-accounts.json (shared with aa-sui_snappymail).
 *
 * Storage shape (matches Hm_Server_List trait via Hm_Repository, see
 * lib/repository.php:38-57 + lib/servers.php:193-197):
 *   imap_servers / smtp_servers / jmap_servers = uniqid-keyed dict;
 *   each entity has id field = its array key.
 */
declare(strict_types=1);

namespace CyphtApi;

class AccountsApi {
    /**
     * Returns a counts summary: ['imap' => int, 'smtp' => int, 'jmap' => int, 'skipped' => string[]]
     */
    public static function apply(\Hm_User_Config_DB $userConfig, array $accountsCfg, string $configsDir): array {
        $sourceRel = $accountsCfg['source'] ?? 'seed-accounts.json';
        $path = \realpath($configsDir . '/' . $sourceRel);
        if ($path === false || !\file_exists($path)) {
            \fwrite(STDERR, "[cypht-api/accounts] source file missing: $sourceRel\n");
            return ['imap' => 0, 'smtp' => 0, 'jmap' => 0, 'skipped' => []];
        }
        $seed = \json_decode(\file_get_contents($path), true);
        if (!\is_array($seed) || empty($seed['extras'])) {
            \fwrite(STDERR, "[cypht-api/accounts] invalid seed JSON at $path\n");
            return ['imap' => 0, 'smtp' => 0, 'jmap' => 0, 'skipped' => []];
        }

        // CRITICAL: Cypht has NO separate jmap_servers key. JMAP entries live
        // inside imap_servers with type='jmap'. Verified in upstream cypht-org/cypht
        // at modules/imap/handler_modules.php (Hm_Handler_process_add_jmap_server
        // calls Hm_IMAP_List::add). The Servers UI counts type='jmap' rows as
        // JMAP and the rest as IMAP. Writing to a 'jmap_servers' key is dead
        // storage — UI never reads it.
        $imap = []; $smtp = []; $imapCount = 0; $jmapCount = 0; $skipped = [];
        foreach ($seed['extras'] as $extra) {
            $passEnv = $extra['pass_env'] ?? '';
            $pass    = $passEnv ? (\getenv($passEnv) ?: '') : '';
            if ($pass === '' || \str_starts_with($pass, 'TODO_')) {
                \fwrite(STDERR, "[cypht-api/accounts] env $passEnv unset/placeholder — skipping {$extra['email']}\n");
                $skipped[] = $extra['email'];
                continue;
            }
            $extra['_pass'] = $pass;
            if ($e = self::buildImap($extra)) { [$id, $ent] = repoEntity($e); $imap[$id] = $ent; $imapCount++; }
            if ($e = self::buildSmtp($extra)) { [$id, $ent] = repoEntity($e); $smtp[$id] = $ent; }
            if ($e = self::buildJmap($extra)) { [$id, $ent] = repoEntity($e); $imap[$id] = $ent; $jmapCount++; }
        }

        $userConfig->set('imap_servers', $imap);
        $userConfig->set('smtp_servers', $smtp);
        // Explicitly clear any legacy jmap_servers key (was written by an
        // earlier version of this seeder; UI never read it).
        $userConfig->set('jmap_servers', []);

        return [
            'imap'    => $imapCount,
            'smtp'    => \count($smtp),
            'jmap'    => $jmapCount,
            'skipped' => $skipped,
        ];
    }

    private static function buildImap(array $extra): ?array {
        if (empty($extra['imap']) || !\is_array($extra['imap'])) return null;
        $i = $extra['imap'];
        $secure = $i['secure'] ?? 'TLS';
        return [
            'name'   => $extra['name'] ?? $extra['email'],
            'server' => $i['host'],
            'port'   => (int)($i['port'] ?? 993),
            'tls'    => $secure !== 'STARTTLS' && $secure !== '',
            'hide'   => false,
            'user'   => $extra['login'] ?? $extra['email'],
            'pass'   => $extra['_pass'],
        ];
    }

    private static function buildSmtp(array $extra): ?array {
        if (empty($extra['smtp']) || !\is_array($extra['smtp'])) return null;
        $s = $extra['smtp'];
        $secure = $s['secure'] ?? 'SSL';
        return [
            'name'   => $extra['name'] ?? $extra['email'],
            'server' => $s['host'],
            'port'   => (int)($s['port'] ?? 465),
            'tls'    => $secure !== 'STARTTLS' && $secure !== '',
            'user'   => $extra['login'] ?? $extra['email'],
            'pass'   => $extra['_pass'],
        ];
    }

    private static function buildJmap(array $extra): ?array {
        if (empty($extra['jmap']) || !\is_array($extra['jmap'])) return null;
        $j = $extra['jmap'];
        $port = $j['port'] ?? null;
        $url  = $j['url'] ?? \sprintf('https://%s%s/.well-known/jmap', $j['host'], $port ? ":$port" : '');
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
}
