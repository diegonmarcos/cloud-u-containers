rule container_escape_proc_mount {
    meta:
        description = "Detects attempts to mount host /proc for container escape"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "mount -t proc" ascii
        $s2 = "/proc/1/root" ascii
        $s3 = "/proc/sysrq-trigger" ascii
        $s4 = "cat /proc/1/cgroup" ascii
        $s5 = "/proc/self/exe" ascii
        $release = "release_agent" ascii
        $notify = "notify_on_release" ascii

    condition:
        any of ($s*) or ($release and $notify)
}

rule container_escape_nsenter {
    meta:
        description = "Detects nsenter-based container escape"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "nsenter" ascii
        $s2 = "--target 1" ascii
        $s3 = "--mount" ascii
        $s4 = "--pid" ascii
        $s5 = "--net" ascii
        $host1 = "/host" ascii
        $host2 = "hostPID" ascii

    condition:
        $s1 and any of ($s2, $s3, $s4, $s5) or ($s1 and any of ($host*))
}

rule container_escape_cgroup {
    meta:
        description = "Detects cgroup-based container escape techniques"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "/sys/fs/cgroup" ascii
        $s2 = "release_agent" ascii
        $s3 = "notify_on_release" ascii
        $s4 = "cgroup.procs" ascii
        $write1 = "echo 1 >" ascii
        $cmd = "/cmd" ascii

    condition:
        ($s1 and $s2 and $s3) or ($s4 and $write1 and $cmd)
}

rule container_escape_docker_socket {
    meta:
        description = "Detects Docker socket access from within container"
        severity = "warning"
        author = "cloud-sec-data"

    strings:
        $s1 = "/var/run/docker.sock" ascii
        $s2 = "docker.sock" ascii
        $s3 = "/run/docker.sock" ascii
        $api1 = "unix:///var/run/docker.sock" ascii
        $api2 = "http:/v1." ascii
        $curl = "curl --unix-socket" ascii

    condition:
        2 of them
}
