const SECURITY = {
  "date": "2025-12-15",
  "timestamp": "2025-12-15T23:22:46.110822",
  "vms": {
    "gcp-f-micro_1": {
      "failed_ssh": [
        [
          "165.22.218.150",
          60
        ],
        [
          "185.242.247.154",
          52
        ],
        [
          "122.54.18.220",
          14
        ],
        [
          "104.152.40.8",
          11
        ],
        [
          "193.46.255.244",
          9
        ],
        [
          "193.46.255.33",
          9
        ],
        [
          "62.60.131.157",
          7
        ],
        [
          "93.152.230.186",
          7
        ],
        [
          "2.57.121.25",
          7
        ],
        [
          "80.94.95.116",
          6
        ],
        [
          "40.76.117.246",
          4
        ],
        [
          "181.0.192.28",
          4
        ],
        [
          "94.156.14.6",
          3
        ],
        [
          "80.94.95.115",
          1
        ]
      ],
      "open_ports": [
        {
          "port": "127.0.0.1:9091",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:8000",
          "process": "users:((\"python3\",pid=317164,fd=3))"
        },
        {
          "port": "127.0.0.1:46563",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:5000",
          "process": "0.0.0.0:*"
        },
        {
          "port": "127.0.0.54:53",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:443",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:22",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:8765",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:81",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:80",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:4180",
          "process": "0.0.0.0:*"
        },
        {
          "port": "127.0.0.53%lo:53",
          "process": "0.0.0.0:*"
        },
        {
          "port": "0.0.0.0:5355",
          "process": "0.0.0.0:*"
        },
        {
          "port": "[::]:5000",
          "process": "[::]:*"
        },
        {
          "port": "[::]:443",
          "process": "[::]:*"
        },
        {
          "port": "[::]:22",
          "process": "[::]:*"
        },
        {
          "port": "[::]:8765",
          "process": "[::]:*"
        },
        {
          "port": "[::]:81",
          "process": "[::]:*"
        },
        {
          "port": "[::]:80",
          "process": "[::]:*"
        },
        {
          "port": "[::]:4180",
          "process": "[::]:*"
        },
        {
          "port": "[::]:5355",
          "process": "[::]:*"
        }
      ],
      "issues": [],
      "total_failed_attempts": 194
    }
  },
  "alerts": [
    {
      "level": "critical",
      "vm": "oci-f-micro_1",
      "message": "VM unreachable"
    },
    {
      "level": "critical",
      "vm": "oci-f-micro_2",
      "message": "VM unreachable"
    },
    {
      "level": "critical",
      "vm": "oci-p-flex_1",
      "message": "VM unreachable"
    }
  ],
  "summary": {
    "total_failed_ssh": 194,
    "unique_attackers": 14,
    "vms_with_issues": 0
  }
};
