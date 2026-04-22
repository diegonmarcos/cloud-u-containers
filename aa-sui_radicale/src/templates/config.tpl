[server]
hosts = 0.0.0.0:@APP_PORT@

[auth]
type = imap
imap_host = @MADDY_IP@:@MADDY_IMAP_PORT@
imap_security = tls

[storage]
filesystem_folder = /data/collections

[rights]
type = owner_only

[logging]
level = debug

[web]
type = internal
