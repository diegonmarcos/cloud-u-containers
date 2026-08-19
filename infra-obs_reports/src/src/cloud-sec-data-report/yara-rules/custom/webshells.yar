rule webshell_php_c99 {
    meta:
        description = "Detects c99 PHP webshell"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "c99shell" ascii nocase
        $s2 = "c99_sess_put" ascii
        $s3 = "$shell_data" ascii
        $s4 = "safe_mode" ascii
        $eval1 = "eval(base64_decode(" ascii
        $eval2 = "eval(gzinflate(" ascii
        $eval3 = "eval(gzuncompress(" ascii
        $func1 = "passthru(" ascii
        $func2 = "shell_exec(" ascii

    condition:
        any of ($s*) or (any of ($eval*) and any of ($func*))
}

rule webshell_php_r57 {
    meta:
        description = "Detects r57 PHP webshell"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "r57shell" ascii nocase
        $s2 = "r57_logo" ascii
        $s3 = "uname -a" ascii
        $back1 = "fsockopen(" ascii
        $back2 = "proc_open(" ascii
        $back3 = "popen(" ascii
        $obf1 = "chr(ord(" ascii
        $obf2 = "str_rot13(" ascii

    condition:
        any of ($s*) or (2 of ($back*) and any of ($obf*))
}

rule webshell_wso {
    meta:
        description = "Detects WSO (Web Shell by oRb) webshell"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "WSO " ascii
        $s2 = "Web Shell by oRb" ascii
        $s3 = "FilesMan" ascii
        $func1 = "pcntl_exec" ascii
        $func2 = "posix_getpwuid" ascii
        $func3 = "posix_getgrgid" ascii
        $auth = "$auth_pass" ascii

    condition:
        any of ($s*) or ($auth and 2 of ($func*))
}

rule webshell_python_generic {
    meta:
        description = "Detects Python-based webshell patterns"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "import subprocess" ascii
        $s2 = "import pty" ascii
        $s3 = "os.system(" ascii
        $s4 = "subprocess.Popen(" ascii
        $s5 = "pty.spawn(" ascii
        $net1 = "socket.socket(" ascii
        $net2 = "SOCK_STREAM" ascii
        $shell1 = "/bin/sh" ascii
        $shell2 = "/bin/bash" ascii

    condition:
        ($s2 and $s5 and any of ($shell*)) or
        (any of ($net*) and any of ($s3, $s4) and any of ($shell*))
}
