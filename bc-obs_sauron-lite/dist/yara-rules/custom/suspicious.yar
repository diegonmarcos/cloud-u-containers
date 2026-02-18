rule Suspicious_Reverse_Shell {
    meta:
        description = "Detects reverse shell patterns"
        severity = "critical"
    strings:
        $bash1 = "/dev/tcp/" nocase
        $bash2 = "bash -i >&" nocase
        $nc1 = "nc -e /bin" nocase
        $nc2 = "ncat -e" nocase
        $py1 = "socket.socket" nocase
        $py2 = "subprocess.call" nocase
        $py3 = "pty.spawn" nocase
        $perl1 = "perl -e" nocase
        $perl2 = "IO::Socket::INET" nocase
    condition:
        ($bash1 or $bash2) or
        ($nc1 or $nc2) or
        ($py1 and $py2 and $py3) or
        ($perl1 and $perl2)
}

rule Suspicious_Credential_Access {
    meta:
        description = "Detects credential harvesting attempts"
        severity = "high"
    strings:
        $shadow = "/etc/shadow" nocase
        $passwd = "/etc/passwd" nocase
        $ssh1 = ".ssh/id_rsa" nocase
        $ssh2 = ".ssh/authorized_keys" nocase
        $aws = ".aws/credentials" nocase
        $docker = ".docker/config.json" nocase
        $kube = ".kube/config" nocase
    condition:
        2 of them
}

rule Suspicious_Encoded_Payload {
    meta:
        description = "Detects heavily encoded/obfuscated content"
        severity = "medium"
    strings:
        $b64_long = /[A-Za-z0-9+\/]{100,}={0,2}/
        $hex_long = /\\x[0-9a-fA-F]{2}(\\x[0-9a-fA-F]{2}){50,}/
        $gzip_b64 = "H4sIA"
    condition:
        any of them
}

rule Suspicious_Docker_Escape {
    meta:
        description = "Detects container escape attempts"
        severity = "critical"
    strings:
        $docker1 = "/var/run/docker.sock" nocase
        $docker2 = "docker.sock" nocase
        $cgroup = "/sys/fs/cgroup" nocase
        $proc = "/proc/1/root" nocase
        $nsenter = "nsenter" nocase
    condition:
        any of them
}
