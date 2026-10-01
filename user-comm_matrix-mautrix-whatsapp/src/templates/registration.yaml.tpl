# Appservice registration for the Continuwuity homeserver. as_token / hs_token
# are ${PLACEHOLDERS} injected from .secrets by the deploy pre_hook. The
# homeserver installs the rendered file itself on every start
# (matrix-continuwuity build.json `appservices` -> admin_execute), so this
# sops pair is the only place the tokens are declared. Deploy this bridge
# before the homeserver when rotating them.
id: whatsapp
url: @APPSERVICE_ADDRESS@
as_token: "${AS_TOKEN}"
hs_token: "${HS_TOKEN}"
sender_localpart: _bot_whatsappbot
rate_limited: false
namespaces:
    users:
        - regex: '^@whatsappbot:@DOMAIN@$'
          exclusive: true
        - regex: '^@whatsapp_.*:@DOMAIN@$'
          exclusive: true
    aliases:
        - regex: '^#whatsapp_.*:@DOMAIN@$'
          exclusive: true
