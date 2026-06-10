# Appservice registration for the Continuwuity homeserver. as_token / hs_token
# are ${PLACEHOLDERS} injected from .secrets by the deploy pre_hook. After
# deploy, register this (rendered) file once via the homeserver admin room:
#   !admin appservices register   (paste the rendered registration.yaml body)
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
