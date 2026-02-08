# Cloud Control - Cost

> **Version**: 1.0.0
> **Generated**: 2025-12-23 18:37
> **Last Data Update**: 2025-12-23
> **Updated By**: manual
> **Source**: `cloud_control.json` -> `cost`

This document is auto-generated from `cloud_control.json` using `cloud_json_export.py`.
Do not edit manually - changes will be overwritten.

---

# Cost

*Cost information - spend, free tier, market comparison*

## Cost Summary

| Metric                       | Value        |
| ---------------------------- | ------------ |
| Total Cloud Spend (All Time) | €0.83        |
| This Month (Dec 2025)        | €0.83        |
| Projected (Full Month)       | €3.22        |
| Year to Date (2025)          | €0.83        |
| Savings vs Market            | €44.17 (98%) |

## Provider Distribution

| Provider           | Cost  | Percentage |
| ------------------ | ----- | ---------- |
| Oracle Cloud (OCI) | €0.83 | 100%       |
| Google Cloud (GCP) | €0.00 | 0%         |

## Infrastructure Breakdown

| Provider     | VM            | Tier        | Cost     |
| ------------ | ------------- | ----------- | -------- |
| Oracle       | oci-p-flex_1  | Paid (Flex) | €5.50/mo |
| Oracle       | oci-f-micro_1 | Always Free | €0/mo    |
| Oracle       | oci-f-micro_2 | Always Free | €0/mo    |
| Google       | gcp-f-micro_1 | Free Tier   | €0/mo    |
| Cloudflare   | DNS           | Free        | €0/mo    |
| GitHub Pages | Hosting       | Free        | €0/mo    |

## Resource Usage by VM

### OCI Paid Flex 1

*Specs: 1 OCPU, 8 GB RAM, 242 GB*

**Total**: CPU 15%, RAM 45%, Storage 68%

| Service    | CPU | RAM | Storage |
| ---------- | --- | --- | ------- |
| photoprism | 5%  | 15% | 21%     |
| radicale   | <1% | 1%  | <1%     |
| cloud-api  | 1%  | 2%  | <1%     |
| openvpn    | <1% | <1% | <1%     |
| redis      | 1%  | <1% | <1%     |

### OCI Free Micro 1

*Specs: 1 OCPU, 1 GB RAM, 47 GB*

**Total**: CPU 5%, RAM 60%, Storage 27%

| Service       | CPU | RAM | Storage |
| ------------- | --- | --- | ------- |
| mailu-front   | 1%  | 8%  | 2%      |
| mailu-admin   | 1%  | 12% | 1%      |
| mailu-imap    | 2%  | 20% | 15%     |
| mailu-smtp    | 1%  | 10% | 5%      |
| mailu-webmail | <1% | 10% | 4%      |

### OCI Free Micro 2

*Specs: 1 OCPU, 1 GB RAM, 47 GB*

**Total**: CPU 10%, RAM 55%, Storage 20%

| Service    | CPU | RAM | Storage |
| ---------- | --- | --- | ------- |
| matomo-app | 5%  | 25% | 5%      |
| matomo-db  | 5%  | 30% | 15%     |

### GCP Free Micro 1

*Specs: 0.25 vCPU, 1 GB RAM, 30 GB*

**Total**: CPU 20%, RAM 70%, Storage 35%

| Service        | CPU | RAM | Storage |
| -------------- | --- | --- | ------- |
| npm            | 8%  | 25% | 10%     |
| authelia       | 3%  | 15% | 5%      |
| authelia-redis | 1%  | 10% | 3%      |
| wireguard      | 5%  | 10% | 1%      |
| oauth2-proxy   | 3%  | 10% | 1%      |

## Free Tier Utilization

### Oracle Cloud (OCI) (Always Free Tier)

| Resource       | Usage | Limit          | Notes                            |
| -------------- | ----- | -------------- | -------------------------------- |
| Compute (ARM)  | 0%    | 4 OCPU + 24 GB | Available                        |
| Block Storage  | 25%   | 200 GB         | ~94 GB used (2x47 GB free micro) |
| Object Storage | 1%    | 20 GB          | < 1 GB used                      |
| VCN Egress     | 0%    | 10 TB/month    | < 1 GB used                      |

### Google Cloud (GCP) (Free Tier)

| Resource       | Usage | Limit      | Notes        |
| -------------- | ----- | ---------- | ------------ |
| Compute Engine | 100%  | 1 e2-micro | 730 hrs/mo   |
| Cloud Storage  | 10%   | 5 GB       | < 1 GB used  |
| Cloud DNS      | 4%    | 25 zones   | 1 zone       |
| Network Egress | 50%   | 1 GB/month | ~0.5 GB used |

## Market Comparison

| Provider         | Cost      | Equivalent Specs     |
| ---------------- | --------- | -------------------- |
| Your Cost        | €0.83/mo  | OCI + GCP Free Tier  |
| AWS Equivalent   | €45.00/mo | t3.medium + 50GB EBS |
| Azure Equivalent | €42.00/mo | B2s + 50GB SSD       |
