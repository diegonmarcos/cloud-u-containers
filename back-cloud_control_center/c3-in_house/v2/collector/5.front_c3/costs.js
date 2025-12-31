const COSTS = {
  "date": "2025-12-15",
  "month": "2025-12",
  "gcp": {
    "status": "ok",
    "accounts": [
      {
        "currencyCode": "EUR",
        "displayName": "My Billing Account",
        "masterBillingAccount": "",
        "name": "billingAccounts/016370-B652E5-7E0A8A",
        "open": true,
        "parent": "organizations/989817648036"
      }
    ],
    "project": {},
    "tier": "free",
    "note": "GCP Free Tier - check console.cloud.google.com/billing"
  },
  "oci": {
    "status": "ok",
    "tenancy": {
      "defined-tags": {},
      "description": "diegonmarcos",
      "freeform-tags": {},
      "home-region-key": "MRS",
      "id": "ocid1.tenancy.oc1..aaaaaaaate22jsouuzgaw65ucwvufcj3lzjxw4ithwcz3cxw6iom6ys2ldsq",
      "name": "diegonmarcos",
      "upi-idcs-compatibility-layer-endpoint": null
    },
    "tier": "always-free",
    "note": "OCI Always Free Tier - check console.oracle.com"
  },
  "claude": {},
  "resources": {
    "status": "error",
    "error": "unsupported operand type(s) for +: 'int' and 'str'"
  },
  "summary": {
    "estimated_monthly_cost": 0,
    "cloud_cost": "Free tier"
  }
};
