[server]
hosts = 0.0.0.0:@APP_PORT@

[auth]
type = imap
imap_host = @IMAP_HOST@:@IMAP_PORT@
imap_security = tls

[storage]
filesystem_folder = /data/collections

[rights]
type = owner_only

[logging]
level = debug

[web]
type = internal
