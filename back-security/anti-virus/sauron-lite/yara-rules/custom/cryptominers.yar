rule CryptoMiner_Generic {
    meta:
        description = "Detects cryptocurrency mining scripts"
        severity = "medium"
    strings:
        $miner1 = "stratum+tcp://" nocase
        $miner2 = "xmrig" nocase
        $miner3 = "minerd" nocase
        $miner4 = "cpuminer" nocase
        $miner5 = "cryptonight" nocase
        $miner6 = "coinhive" nocase
        $miner7 = "coin-hive" nocase
        $pool1 = "pool.minexmr.com" nocase
        $pool2 = "xmrpool.eu" nocase
        $pool3 = "supportxmr.com" nocase
    condition:
        any of them
}

rule CryptoMiner_JavaScript {
    meta:
        description = "Detects browser-based crypto miners"
        severity = "medium"
    strings:
        $js1 = "CoinHive.Anonymous" nocase
        $js2 = "coinhive.min.js" nocase
        $js3 = "cryptoloot" nocase
        $js4 = "webminepool" nocase
        $js5 = "miner.start()" nocase
    condition:
        any of them
}
