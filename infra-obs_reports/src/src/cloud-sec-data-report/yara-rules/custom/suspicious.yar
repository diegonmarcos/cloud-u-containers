rule reverse_shell_bash {
    meta:
        description = "Detects bash reverse shell patterns"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "bash -i >& /dev/tcp/" ascii
        $s2 = "bash -c 'bash -i >& /dev/tcp/" ascii
        $s3 = "/dev/tcp/" ascii
        $s4 = "0>&1" ascii
        $s5 = "exec 5<>/dev/tcp/" ascii
        $nc1 = "nc -e /bin/" ascii
        $nc2 = "ncat -e /bin/" ascii
        $nc3 = "netcat -e /bin/" ascii

    condition:
        ($s1 or $s2) or ($s3 and $s4) or $s5 or any of ($nc*)
}

rule reverse_shell_python {
    meta:
        description = "Detects Python reverse shell patterns"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "socket.socket(socket.AF_INET" ascii
        $s2 = ".connect((" ascii
        $s3 = "subprocess.call([\"/bin/sh\"" ascii
        $s4 = "subprocess.call([\"/bin/bash\"" ascii
        $s5 = "os.dup2(s.fileno()" ascii
        $s6 = "pty.spawn(\"/bin" ascii

    condition:
        ($s1 and $s2 and any of ($s3, $s4, $s5)) or ($s1 and $s6)
}

rule bind_shell {
    meta:
        description = "Detects bind shell patterns"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "socket.bind((" ascii
        $s2 = "socket.listen(" ascii
        $s3 = "socket.accept()" ascii
        $exec1 = "subprocess.Popen([\"/bin/sh\"" ascii
        $exec2 = "os.system(\"/bin/sh\"" ascii
        $socat = "socat TCP-LISTEN:" ascii
        $nc = "nc -lvp" ascii

    condition:
        ($s1 and $s2 and $s3 and any of ($exec*)) or $socat or $nc
}

rule suspicious_cron_entry {
    meta:
        description = "Detects suspicious cron job patterns"
        severity = "warning"
        author = "cloud-sec-data"

    strings:
        $cron1 = "*/5 * * * *" ascii
        $cron2 = "*/1 * * * *" ascii
        $cron3 = "@reboot" ascii
        $dl1 = "curl " ascii
        $dl2 = "wget " ascii
        $pipe1 = "| sh" ascii
        $pipe2 = "| bash" ascii
        $pipe3 = "| /bin/sh" ascii
        $pipe4 = "| /bin/bash" ascii
        $b64 = "base64 -d" ascii

    condition:
        any of ($cron*) and (any of ($dl*) and (any of ($pipe*) or $b64))
}
