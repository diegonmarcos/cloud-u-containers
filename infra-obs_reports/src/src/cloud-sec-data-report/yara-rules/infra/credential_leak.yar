rule exposed_ssh_private_key {
    meta:
        description = "Detects exposed SSH private keys"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $rsa = "-----BEGIN RSA PRIVATE KEY-----" ascii
        $openssh = "-----BEGIN OPENSSH PRIVATE KEY-----" ascii
        $ec = "-----BEGIN EC PRIVATE KEY-----" ascii
        $dsa = "-----BEGIN DSA PRIVATE KEY-----" ascii
        $ed25519 = "-----BEGIN PRIVATE KEY-----" ascii

    condition:
        any of them
}

rule exposed_api_token {
    meta:
        description = "Detects exposed API tokens and keys"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $aws1 = /AKIA[0-9A-Z]{16}/ ascii
        $gcp1 = /AIza[0-9A-Za-z_-]{35}/ ascii
        $gh1 = /ghp_[0-9A-Za-z]{36}/ ascii
        $gh2 = /gho_[0-9A-Za-z]{36}/ ascii
        $gh3 = /github_pat_[0-9A-Za-z_]{82}/ ascii
        $slack = /xox[bprs]-[0-9A-Za-z-]{10,}/ ascii

    condition:
        any of them
}

rule exposed_env_secrets {
    meta:
        description = "Detects .env files containing secrets"
        severity = "warning"
        author = "cloud-sec-data"

    strings:
        $db1 = /DATABASE_URL=postgres:\/\/[^\s]+/ ascii
        $db2 = /MYSQL_PASSWORD=[^\s]{8,}/ ascii
        $db3 = /REDIS_PASSWORD=[^\s]{8,}/ ascii
        $api1 = /API_KEY=[^\s]{16,}/ ascii
        $api2 = /SECRET_KEY=[^\s]{16,}/ ascii
        $api3 = /JWT_SECRET=[^\s]{16,}/ ascii
        $smtp = /SMTP_PASSWORD=[^\s]{8,}/ ascii
        $s3 = /AWS_SECRET_ACCESS_KEY=[^\s]{20,}/ ascii

    condition:
        2 of them
}

rule exposed_certificate_key {
    meta:
        description = "Detects exposed TLS/SSL private keys"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "-----BEGIN CERTIFICATE-----" ascii
        $s2 = "-----BEGIN PRIVATE KEY-----" ascii
        $s3 = "-----BEGIN RSA PRIVATE KEY-----" ascii
        $s4 = "-----BEGIN EC PRIVATE KEY-----" ascii

    condition:
        $s1 and any of ($s2, $s3, $s4)
}
