; SnappyMail domain config — Gmail (Google consumer)
; Maps logins of the form <user>@gmail.com to Gmail IMAP + SMTP.
; Requires an app-password generated in Google Account security settings.
imap_host = "imap.gmail.com"
imap_port = 993
imap_secure = "SSL"
imap_short_login = 0

smtp_host = "smtp.gmail.com"
smtp_port = 587
smtp_secure = "TLS"
smtp_short_login = 0
smtp_auth = 1
smtp_set_sender = 0

white_list = ""
