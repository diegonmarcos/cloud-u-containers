# Cloud Architecture API Reference

> **Version**: 1.0.0
> **Generated**: 2025-12-23 17:32
> **Source**: `cloud_architecture_api.json`

This document is auto-generated from `cloud_architecture_api.json` using `cloud_json_md.py`.
Do not edit manually - changes will be overwritten.

---


## API Overview

**Title**: Cloud Architecture API

**Version**: 1.0.0

**Description**: REST API endpoints for cloud_architecture.json - static infrastructure definitions (VMs, services, domains, networks)


### Servers

| Environment | Base URL                     | Description                         |
| ----------- | ---------------------------- | ----------------------------------- |
| production  | https://api.diegonmarcos.com | Production API via NPM proxy        |
| internal    | http://127.0.0.1:5000        | Direct Flask access (internal only) |
| dev         | http://localhost:5000        | Local development                   |

### Authentication

**Type**: bearer

**Provider**: authelia

**Token Endpoint**: `https://auth.diegonmarcos.com/api/oidc/token`


### Auth Scopes

| Scope | Description                               |
| ----- | ----------------------------------------- |
| read  | Read-only access to all data              |
| write | Modify runtime status and trigger actions |
| admin | Full access including VM control          |

## Endpoints Summary

| Category     | Description                                                             | Endpoints |
| ------------ | ----------------------------------------------------------------------- | --------- |
| health       | API health and status checks                                            | 2         |
| architecture | Access cloud_architecture.json data (static infrastructure definitions) | 8         |
| vms          | Virtual machine definitions (static data)                               | 3         |
| services     | Service definitions (static data)                                       | 2         |
| domains      | Domain configuration (static data)                                      | 2         |
| index        | API discovery and metadata                                              | 2         |


**Total Endpoints**: 18

## Endpoints Detail

### HEALTH

*API health and status checks*


| Method | Path            | Auth | Description                             |
| ------ | --------------- | ---- | --------------------------------------- |
| `GET`  | `/health`       | none | Simple health check                     |
| `GET`  | `/health/ready` | none | Readiness check (DB, cache connections) |

### ARCHITECTURE

*Access cloud_architecture.json data (static infrastructure definitions)*

**Source**: `cloud_architecture.json`


| Method | Path                           | Auth | Description                           |
| ------ | ------------------------------ | ---- | ------------------------------------- |
| `GET`  | `/architecture`                | read | Get complete architecture.json        |
| `GET`  | `/architecture/overview`       | read | Get partI_overview section            |
| `GET`  | `/architecture/infrastructure` | read | Get partII_infrastructure section     |
| `GET`  | `/architecture/security`       | read | Get partIII_security section          |
| `GET`  | `/architecture/data`           | read | Get partIV_data section               |
| `GET`  | `/architecture/operations`     | read | Get partV_operations section          |
| `GET`  | `/architecture/reference`      | read | Get partVI_reference section          |
| `GET`  | `/architecture/version`        | none | Get architecture version and metadata |

### VMS

*Virtual machine definitions (static data)*

**Source**: `cloud_architecture.partII_infrastructure.virtualMachines`


| Method | Path              | Auth | Description                       |
| ------ | ----------------- | ---- | --------------------------------- |
| `GET`  | `/vms`            | read | List all virtual machines         |
| `GET`  | `/vms/{vmId}`     | read | Get single VM details             |
| `GET`  | `/vms/{vmId}/ssh` | read | Get SSH connection command for VM |

### SERVICES

*Service definitions (static data)*

**Source**: `cloud_architecture.partII_infrastructure.services`


| Method | Path                    | Auth | Description                |
| ------ | ----------------------- | ---- | -------------------------- |
| `GET`  | `/services`             | read | List all services          |
| `GET`  | `/services/{serviceId}` | read | Get single service details |

### DOMAINS

*Domain configuration (static data)*

**Source**: `cloud_architecture.partIII_security.domains`


| Method | Path                | Auth | Description                     |
| ------ | ------------------- | ---- | ------------------------------- |
| `GET`  | `/domains`          | read | List all domains and subdomains |
| `GET`  | `/domains/{domain}` | read | Get domain configuration        |

### INDEX

*API discovery and metadata*


| Method | Path        | Auth | Description                            |
| ------ | ----------- | ---- | -------------------------------------- |
| `GET`  | `/`         | none | API root - returns available endpoints |
| `GET`  | `/api/docs` | none | Get API specification                  |

## Curl Examples

### health

| Endpoint | Curl Command                               |
| -------- | ------------------------------------------ |
| ping     | `curl https://api.diegonmarcos.com/health` |

### architecture

| Endpoint | Curl Command                                                                       |
| -------- | ---------------------------------------------------------------------------------- |
| full     | `curl -H 'Authorization: Bearer $TOKEN' https://api.diegonmarcos.com/architecture` |

### vms

| Endpoint | Curl Command                                                                           |
| -------- | -------------------------------------------------------------------------------------- |
| list     | `curl -H 'Authorization: Bearer $TOKEN' https://api.diegonmarcos.com/vms`              |
| get      | `curl -H 'Authorization: Bearer $TOKEN' https://api.diegonmarcos.com/vms/oci-p-flex_1` |

## Schemas

### VirtualMachine

| Property     | Type                       | Required | Description |
| ------------ | -------------------------- | -------- | ----------- |
| id           | string                     | Yes      |             |
| name         | string                     | Yes      |             |
| displayName  | string                     | No       |             |
| provider     | enum: oracle, gcloud       | Yes      |             |
| category     | enum: services, ml         | No       |             |
| instanceType | string                     | No       |             |
| specs        | object                     | No       |             |
| network      | object                     | Yes      |             |
| availability | enum: 24/7, wake-on-demand | No       |             |
| cost         | object                     | No       |             |

### Service

| Property     | Type    | Required | Description |
| ------------ | ------- | -------- | ----------- |
| id           | string  | Yes      |             |
| displayName  | string  | Yes      |             |
| category     | string  | Yes      |             |
| vmId         | string  | Yes      |             |
| containers   | array   | No       |             |
| technology   | object  | No       |             |
| urls         | object  | No       |             |
| authRequired | boolean | No       |             |
| resources    | object  | No       |             |

### Domain

| Property | Type                         | Required | Description |
| -------- | ---------------------------- | -------- | ----------- |
| service  | string                       | Yes      |             |
| vmId     | string                       | No       |             |
| proxyVia | string                       | No       |             |
| ssl      | boolean                      | Yes      |             |
| auth     | enum: none, authelia, native | No       |             |

### ApiError

| Property | Type   | Required | Description |
| -------- | ------ | -------- | ----------- |
| error    | string | No       |             |
| code     | string | No       |             |
| message  | string | No       |             |
| details  | object | No       |             |

## Error Codes

| HTTP Code | Error Code     | Message                                  |
| --------- | -------------- | ---------------------------------------- |
| 400       | BAD_REQUEST    | Invalid request parameters               |
| 401       | UNAUTHORIZED   | Missing or invalid authentication token  |
| 403       | FORBIDDEN      | Insufficient permissions for this action |
| 404       | NOT_FOUND      | Resource not found                       |
| 500       | INTERNAL_ERROR | Internal server error                    |

### Rate Limits

| Category | Requests | Window |
| -------- | -------- | ------ |
| default  | 100      | 1m     |
| auth     | 10       | 1m     |

## Data Sources Mapping
