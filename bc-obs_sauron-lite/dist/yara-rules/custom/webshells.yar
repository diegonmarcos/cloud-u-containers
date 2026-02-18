rule PHP_WebShell_Generic {
    meta:
        description = "Detects common PHP webshell patterns"
        severity = "high"
        author = "Security Team"
    strings:
        $eval1 = "eval($_POST" nocase
        $eval2 = "eval($_GET" nocase
        $eval3 = "eval($_REQUEST" nocase
        $eval4 = "eval(base64_decode" nocase
        $system1 = "system($_" nocase
        $system2 = "passthru($_" nocase
        $system3 = "shell_exec($_" nocase
        $system4 = "exec($_" nocase
        $b64 = "base64_decode($_" nocase
        $assert = "assert($_" nocase
    condition:
        any of them
}

rule PHP_Backdoor_C99 {
    meta:
        description = "Detects C99 shell variants"
        severity = "critical"
    strings:
        $c99_1 = "c99shell" nocase
        $c99_2 = "c99madshell" nocase
        $c99_3 = "r57shell" nocase
    condition:
        any of them
}

rule JSP_WebShell {
    meta:
        description = "Detects JSP webshell patterns"
        severity = "high"
    strings:
        $jsp1 = "Runtime.getRuntime().exec"
        $jsp2 = "ProcessBuilder"
        $jsp3 = "request.getParameter"
    condition:
        $jsp3 and ($jsp1 or $jsp2)
}
