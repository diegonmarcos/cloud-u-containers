<?php
/**
 * cypht-api/lib/profiles.php
 *
 * Apply send-as profiles to user_config. Storage = 'profiles' key, managed
 * by Hm_Profiles via the same Hm_Repository trait used by Hm_IMAP_List /
 * Hm_SMTP_List — uniqid-keyed dict, each entry carries its own id field.
 *
 * Required entity shape (from upstream cypht-org/cypht
 * modules/profiles/hm-profiles.php + functions.php::add_profile):
 *   { id, name, address, replyto, sig, rmk, smtp_id, imap_id,
 *     server, user, type ('imap'|'jmap'|'ews'), default (bool) }
 *
 * Wiring: each profile entry references a seeded mail account by its display
 * `name` (e.g. "me@dnm.com | IMAP-Maddy"). AccountsApi exports a name → id
 * index for both imap_servers and smtp_servers; ProfilesApi looks up the
 * matching IDs. No manual id strings in configs.json — everything stays
 * declarative and reorder-safe.
 */
declare(strict_types=1);

namespace CyphtApi;

class ProfilesApi {
    /**
     * @param \Hm_User_Config_DB $userConfig
     * @param array              $profilesCfg  configs.json#profiles block
     * @param array              $accounts     return value from AccountsApi::apply
     * @return array{count:int, missing:string[]}
     */
    public static function apply(\Hm_User_Config_DB $userConfig, array $profilesCfg, array $accounts): array {
        $byNameImap = $accounts['by_name_imap'] ?? [];
        $byNameSmtp = $accounts['by_name_smtp'] ?? [];
        $imapRows   = $accounts['imap_rows']    ?? [];
        $smtpRows   = $accounts['smtp_rows']    ?? [];

        $profiles = []; $count = 0; $missing = [];
        $defaultId = null;

        foreach ($profilesCfg as $key => $entry) {
            if (\str_starts_with((string)$key, '_')) continue;
            if (!\is_array($entry)) continue;

            $name    = $entry['name']    ?? (string)$key;
            $address = $entry['address'] ?? '';
            $match   = $entry['match']   ?? $name;
            $replyto = $entry['replyto'] ?? $address;
            $sig     = $entry['sig']     ?? '';
            $rmk     = $entry['rmk']     ?? '';
            $type    = $entry['type']    ?? 'imap';
            $default = !empty($entry['default']);

            $imapId = $byNameImap[$match] ?? null;
            $smtpId = $byNameSmtp[$match] ?? null;
            if ($imapId === null || $smtpId === null) {
                \fwrite(STDERR, "[cypht-api/profiles] '$name': match='$match' missing imap_id or smtp_id — skipping\n");
                $missing[] = $name;
                continue;
            }

            $imapRow = $imapRows[$imapId] ?? [];
            $server  = $imapRow['server'] ?? '';
            $user    = $imapRow['user']   ?? $address;

            $profile = [
                'name'    => $name,
                'address' => $address,
                'replyto' => $replyto,
                'sig'     => $sig,
                'rmk'     => $rmk,
                'smtp_id' => $smtpId,
                'imap_id' => $imapId,
                'server'  => $server,
                'user'    => $user,
                'type'    => $type,
                'default' => $default,
            ];
            [$id, $ent] = repoEntity($profile);
            $profiles[$id] = $ent;
            if ($default) $defaultId = $id;
            $count++;
        }

        // Hm_Profiles::setDefault enforces single default. If config flagged
        // a default but we have multiple profiles, demote the rest.
        if ($defaultId !== null) {
            foreach ($profiles as $pid => &$p) {
                $p['default'] = ($pid === $defaultId);
            }
            unset($p);
        }

        $userConfig->set('profiles', $profiles);
        return ['count' => $count, 'missing' => $missing];
    }
}
