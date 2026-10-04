<?php
/**
 * cypht-api/lib/carddav.php
 *
 * Apply CardDAV providers to user_config.
 * Storage: carddav_contacts_auth_setting (modules/carddav_contacts/modules.php:28)
 * Shape:   {"<source-name>": {"server": str, "user": str, "pass": str}, ...}
 *          Merged in-place (existing entries kept, new keys overlaid).
 */
declare(strict_types=1);

namespace CyphtApi;

class CardDavApi {
    /**
     * Returns ['count' => int]
     */
    public static function apply(\Hm_User_Config_DB $userConfig, array $cardDavCfg, string $primaryEmail): array {
        $existing = $userConfig->get('carddav_contacts_auth_setting', []);
        if (!\is_array($existing)) $existing = [];

        $count = 0;
        foreach ($cardDavCfg as $sourceName => $entry) {
            // Skip doc keys
            if (\str_starts_with((string)$sourceName, '_')) continue;
            if (!\is_array($entry)) continue;

            $passEnv = $entry['pass_env'] ?? '';
            $pass    = $passEnv ? (\getenv($passEnv) ?: '') : '';
            if ($pass === '' || \str_starts_with($pass, 'TODO_')) {
                \fwrite(STDERR, "[cypht-api/carddav] $sourceName: env $passEnv unset/placeholder — skipping\n");
                continue;
            }

            $userEnv = $entry['user_env'] ?? 'PRIMARY_EMAIL';
            $user    = resolveEnv($userEnv, $primaryEmail);
            if ($user === '') {
                \fwrite(STDERR, "[cypht-api/carddav] $sourceName: user unresolved — skipping\n");
                continue;
            }

            $tpl    = $entry['server_template'] ?? '';
            $server = resolveTemplate($tpl, ['user_url_encoded' => $user]);
            if ($server === '') {
                \fwrite(STDERR, "[cypht-api/carddav] $sourceName: server_template empty — skipping\n");
                continue;
            }

            $existing[$sourceName] = ['server' => $server, 'user' => $user, 'pass' => $pass];
            $count++;
        }

        $userConfig->set('carddav_contacts_auth_setting', $existing);
        return ['count' => $count];
    }
}
