; SnappyMail domain config — Microsoft Outlook / Live (consumer)
; Maps logins of the form <user>@live.com to Outlook's IMAP + SMTP.
; Requires an app-password (2FA accounts cannot use the plain password here).
imap_host = "outlook.office365.com"
imap_port = 993
imap_secure = "SSL"
imap_short_login = 0

smtp_host = "smtp-mail.outlook.com"
smtp_port = 587
smtp_secure = "TLS"
smtp_short_login = 0
smtp_auth = 1
smtp_set_sender = 0

white_list = ""
