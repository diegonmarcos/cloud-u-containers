rule persistence_cron_injection {
    meta:
        description = "Detects cron-based persistence mechanisms"
        severity = "warning"
        author = "cloud-sec-data"

    strings:
        $cron1 = "/etc/cron.d/" ascii
        $cron2 = "/etc/crontab" ascii
        $cron3 = "/var/spool/cron" ascii
        $cron4 = "crontab -" ascii
        $dl1 = "curl " ascii
        $dl2 = "wget " ascii
        $shell1 = "/bin/sh" ascii
        $shell2 = "/bin/bash" ascii
        $b64 = "base64" ascii

    condition:
        any of ($cron*) and any of ($dl*) and (any of ($shell*) or $b64)
}

rule persistence_systemd_service {
    meta:
        description = "Detects suspicious systemd service creation"
        severity = "warning"
        author = "cloud-sec-data"

    strings:
        $unit1 = "[Unit]" ascii
        $svc1 = "[Service]" ascii
        $install = "[Install]" ascii
        $exec1 = "ExecStart=/tmp/" ascii
        $exec2 = "ExecStart=/dev/shm/" ascii
        $exec3 = "ExecStart=/var/tmp/" ascii
        $path1 = "/etc/systemd/system/" ascii
        $path2 = "/usr/lib/systemd/system/" ascii
        $restart = "Restart=always" ascii

    condition:
        ($unit1 and $svc1) and (any of ($exec*) or ($restart and any of ($path*)))
}

rule persistence_authorized_keys {
    meta:
        description = "Detects unauthorized SSH authorized_keys modifications"
        severity = "warning"
        author = "cloud-sec-data"

    strings:
        $path1 = ".ssh/authorized_keys" ascii
        $path2 = "/root/.ssh/authorized_keys" ascii
        $cmd1 = "echo " ascii
        $cmd2 = ">> " ascii
        $cmd3 = "ssh-rsa " ascii
        $cmd4 = "ssh-ed25519 " ascii
        $force = "command=" ascii
        $curl = "curl " ascii

    condition:
        any of ($path*) and ($cmd1 and $cmd2 and any of ($cmd3, $cmd4)) or
        (any of ($path*) and ($force or $curl))
}

rule persistence_init_script {
    meta:
        description = "Detects init script persistence"
        severity = "warning"
        author = "cloud-sec-data"

    strings:
        $init1 = "/etc/init.d/" ascii
        $init2 = "/etc/rc.local" ascii
        $init3 = "/etc/rc.d/" ascii
        $profile1 = "/etc/profile.d/" ascii
        $profile2 = "/etc/bashrc" ascii
        $profile3 = "/etc/bash.bashrc" ascii
        $dl1 = "curl " ascii
        $dl2 = "wget " ascii
        $exec1 = "eval " ascii
        $exec2 = "exec " ascii

    condition:
        any of ($init*, $profile*) and (any of ($dl*) or any of ($exec*))
}
