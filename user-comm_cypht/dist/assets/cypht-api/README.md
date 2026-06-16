# cypht-api

Declarative user-config sidecar for the Cypht webmail container.

Cypht has no REST/JSON API for adding mail accounts, contacts, feeds, or
settings — only form-based handlers (verified in upstream `cypht-org/cypht`,
`modules/imap/handler_modules.php:1586-1632`). Scripted form submission
would mean ~50 round trips, CSRF token rotation, HTML scraping for
`hm_page_key`, and brittleness to UI markup changes.

This sidecar takes the canonical path: invoke Cypht's own classes
(`Hm_User_Config_DB`, `Hm_Repository`, `Hm_IMAP_List`/`Hm_SMTP_List`/
`Hm_Feed_List`) with the same encryption + serialization the login
flow uses. One bootstrap, one `save()`, one DB UPDATE.

## Layout

```
cypht-api/
├── configs.json     ← single declarative inventory (the only file you edit)
├── sidecar.sh       ← entrypoint orchestrator (mounted into container, runs at boot)
├── apply.php        ← runner: reads configs.json, dispatches to lib/*
├── verify.php       ← read-only runtime checker (KEY=VALUE on stdout, parseable)
├── lib/
│   ├── bootstrap.php  ← Cypht framework load + Hm_User_Config_DB->load
│   ├── accounts.php   ← AccountsApi  → imap_servers / smtp_servers / jmap_servers
│   ├── carddav.php    ← CardDavApi   → carddav_contacts_auth_setting
│   ├── feeds.php      ← FeedsApi     → feeds  (Hm_Feed_List)
│   └── settings.php   ← SettingsApi  → *_setting keys
└── README.md
```

## configs.json schema

```jsonc
{
  "_doc":     "...",
  "_version": 1,

  "primary_user": {
    "email":    "<master account>",
    "pass_env": "<env var holding the password / master encryption key>"
  },

  "accounts": {
    "source": "<path to seed-accounts.json relative to cypht-api/>"
  },

  "carddav": {
    "<source-name>": {
      "server_template": "https://.../{user_url_encoded}/",
      "user_env":        "PRIMARY_EMAIL | <env var>",
      "pass_env":        "<env var>"
    }
  },

  "feeds": {
    "source":       "<path to topics JSON relative to cypht-api/>",
    "url_template": "https://.../{topic}/..."
  },

  "settings": {
    "<key_setting>": <value>,
    ...
  }
}
```

Tokens supported in templates:
- `{user_url_encoded}` — `rawurlencode(primary_user.email)`
- `{topic}` — `rawurlencode(feed topic)`

`PRIMARY_EMAIL` is a special `user_env` value resolving to the primary email.

Top-level keys starting with `_` (e.g. `_doc`, `_note`) are doc strings and
are ignored at apply time.

## Storage shapes (verified against upstream)

| Module   | user_config key                       | Shape                                                                 |
|----------|---------------------------------------|-----------------------------------------------------------------------|
| accounts | `imap_servers`/`smtp_servers`/`jmap_servers` | uniqid-keyed dict, each entity has `id` field; matches `Hm_Repository` (`lib/repository.php:38-57`) + `Hm_Server_List::add` (`lib/servers.php:193-197`) |
| carddav  | `carddav_contacts_auth_setting`       | named-source dict `{"name": {"server","user","pass"}}`               |
| feeds    | `feeds`                               | uniqid-keyed dict (same trait as IMAP)                                |
| settings | each `*_setting` key                  | scalar                                                                |

## Add a new section

1. Add a `lib/<name>.php` defining `class <Name>Api { public static function apply(...); }`.
2. Add a section to `configs.json`.
3. Add a dispatch line in `apply.php`.
4. Update `verify.php` if the section should appear in runtime output.

## Verifying

```sh
docker exec cypht php /tmp/cypht-config/cypht-api/verify.php
# Expected:
#   decrypt_ok=1
#   primary_email=me@diegonmarcos.com
#   imap_count=3
#   smtp_count=4
#   jmap_count=1
#   feeds_count=17
#   carddav_count=1
#   theme_setting=darkly
#   ...
```

## Why DB injection (not API simulation)

| Aspect                   | DB injection (this)                                | API simulation                          |
|--------------------------|----------------------------------------------------|-----------------------------------------|
| Round trips              | 1 (single `save()`)                                | ~50 (one per entity, plus CSRF refresh) |
| CSRF / form / HTML       | bypassed entirely                                  | scrape `hm_page_key` per request        |
| Encryption / shape       | uses Cypht's own classes — login can decrypt       | identical (same code path on submit)    |
| Resilience to UI changes | high                                               | low (HTML markup churn = breakage)      |
| Hooks/triggers fired     | same as form path (form handler also calls `set` → `save`) | same                                    |

## Caveats

- `migrateFromIntegerIds` in `lib/repository.php:97-153` rewrites integer-keyed
  legacy data to uniqid keys but only updates the in-memory session, NOT
  the encrypted DB blob. We sidestep it by writing uniqid-keyed dicts on
  first save.

- Cypht has NO declarative CalDAV server-list storage (`modules/calendar/`
  only stores `calendar_events`). CalDAV is intentionally out of scope.

- Per-user 2FA enrolment requires the user to scan a TOTP QR into their
  authenticator. We can flip `2fa_enable_setting` true here, but the
  shared secret + QR remain a manual step.
