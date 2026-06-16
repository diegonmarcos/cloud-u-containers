<?php
/**
 * cypht-api/lib/settings.php
 *
 * Apply per-user UI settings to user_config. Each key MUST end in _setting
 * per Cypht convention (modules/core, modules/themes, modules/sievefilters,
 * modules/smtp, modules/contacts).
 *
 * Skips keys starting with "_" (doc keys in configs.json).
 */
declare(strict_types=1);

namespace CyphtApi;

class SettingsApi {
    /**
     * Returns ['count' => int, 'invalid' => string[]]
     */
    public static function apply(\Hm_User_Config_DB $userConfig, array $settingsCfg): array {
        $count = 0;
        $invalid = [];
        foreach ($settingsCfg as $key => $value) {
            if (!\is_string($key)) continue;
            if (\str_starts_with($key, '_')) continue;
            if (!\str_ends_with($key, '_setting')) {
                \fwrite(STDERR, "[cypht-api/settings] invalid key '$key' (must end in _setting) — skipping\n");
                $invalid[] = $key;
                continue;
            }
            $userConfig->set($key, $value);
            $count++;
        }
        return ['count' => $count, 'invalid' => $invalid];
    }
}
