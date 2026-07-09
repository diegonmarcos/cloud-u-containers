# mautrix-whatsapp configuration (overrides). mautrix fills all omitted keys
# with its built-in defaults + auto-upgrades this file on startup. as_token /
# hs_token are ${PLACEHOLDERS} injected from .secrets by the deploy pre_hook —
# they are NEVER stored in this committed template.
homeserver:
    address: @HOMESERVER_ADDRESS@
    domain: @DOMAIN@
    software: standard
    async_media: false

appservice:
    address: @APPSERVICE_ADDRESS@
    hostname: @APPSERVICE_HOSTNAME@
    port: @APPSERVICE_PORT@
    id: whatsapp
    bot:
        username: whatsappbot
        displayname: WhatsApp bridge bot
        avatar: mxc://maunium.net/NeXNQarUbrlYBiPCpprYsRqr
    as_token: "${AS_TOKEN}"
    hs_token: "${HS_TOKEN}"

database:
    type: sqlite3-fk-wal
    uri: @DB_URI@

bridge:
    permissions:
        "@DOMAIN@": user
        "@ADMIN_USER@": admin

double_puppet:
    secrets: {}

encryption:
    allow: true
    default: true
    require: false

logging:
    min_level: info
    writers:
        - type: stdout
          format: pretty-colored
