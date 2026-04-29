<?php
/**
 * cypht-api/lib/feeds.php
 *
 * Apply RSS feeds to user_config.
 * Storage: feeds (Hm_Feed_List, same Hm_Server_List trait as IMAP/SMTP)
 * Shape:   uniqid-keyed dict with id/name/server/tls/port per entity.
 *
 * Source: a JSON file at $configsDir/<feeds.source> with shape
 *   { "topics": ["topic1", "topic2", ...] }
 * (canonical SoT for ntfy: I_cloud-data/ntfy-api/src/topics.json,
 *  copied at flake build time to ../ntfy-topics.json relative to cypht-api/).
 */
declare(strict_types=1);

namespace CyphtApi;

class FeedsApi {
    /**
     * Returns ['count' => int]
     */
    public static function apply(\Hm_User_Config_DB $userConfig, array $feedsCfg, string $configsDir): array {
        $sourceRel = $feedsCfg['source'] ?? '';
        $tpl       = $feedsCfg['url_template'] ?? '';
        if ($sourceRel === '' || $tpl === '') {
            \fwrite(STDERR, "[cypht-api/feeds] missing source or url_template — skipping\n");
            return ['count' => 0];
        }
        $path = \realpath($configsDir . '/' . $sourceRel);
        if ($path === false || !\file_exists($path)) {
            \fwrite(STDERR, "[cypht-api/feeds] source file missing: $sourceRel\n");
            return ['count' => 0];
        }
        $doc = \json_decode(\file_get_contents($path), true);
        $topics = $doc['topics'] ?? (\is_array($doc) ? $doc : []);

        $list = [];
        foreach ($topics as $topic) {
            if (!\is_string($topic) || $topic === '') continue;
            $url = resolveTemplate($tpl, ['topic' => $topic]);
            [$id, $ent] = repoEntity([
                'name'   => $topic,
                'server' => $url,
                'tls'    => true,
                'port'   => 443,
            ]);
            $list[$id] = $ent;
        }

        $userConfig->set('feeds', $list);
        return ['count' => \count($list)];
    }
}
