rule cryptominer_xmrig {
    meta:
        description = "Detects XMRig cryptocurrency miner"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "xmrig" ascii nocase
        $s2 = "stratum+tcp://" ascii
        $s3 = "stratum+ssl://" ascii
        $s4 = "--donate-level" ascii
        $s5 = "\"algo\":\"randomx\"" ascii nocase
        $s6 = "\"algo\":\"cn/" ascii nocase
        $cfg1 = "\"pools\":" ascii
        $cfg2 = "\"user\":\"4" ascii

    condition:
        2 of ($s*) or all of ($cfg*)
}

rule cryptominer_cpuminer {
    meta:
        description = "Detects cpuminer/minerd binary"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "cpuminer" ascii nocase
        $s2 = "minerd" ascii
        $s3 = "--algo=" ascii
        $s4 = "--url=stratum" ascii
        $s5 = "cryptonight" ascii nocase
        $s6 = "scrypt" ascii

    condition:
        ($s1 or $s2) and 2 of ($s3, $s4, $s5, $s6)
}

rule cryptominer_nicehash {
    meta:
        description = "Detects NiceHash miner components"
        severity = "critical"
        author = "cloud-sec-data"

    strings:
        $s1 = "nicehash" ascii nocase
        $s2 = "nhmp.ssl" ascii
        $s3 = "excavator" ascii nocase
        $s4 = "nheqminer" ascii nocase
        $url1 = "stratum.nicehash.com" ascii
        $url2 = "nhmp.nicehash.com" ascii

    condition:
        2 of them
}

rule cryptominer_generic {
    meta:
        description = "Detects generic cryptocurrency mining indicators"
        severity = "warning"
        author = "cloud-sec-data"

    strings:
        $pool1 = "pool.minergate.com" ascii
        $pool2 = "xmr.pool.minergate" ascii
        $pool3 = "moneropool.com" ascii
        $pool4 = "monerohash.com" ascii
        $pool5 = "f2pool.com" ascii
        $algo1 = "randomx" ascii nocase
        $algo2 = "cryptonight" ascii nocase
        $algo3 = "ethash" ascii nocase
        $wallet = /[48][0-9AB][1-9A-HJ-NP-Za-km-z]{93}/ ascii

    condition:
        any of ($pool*) or ($wallet and any of ($algo*))
}
