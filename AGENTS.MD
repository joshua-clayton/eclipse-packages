# Agent Instructions

## Resource Registry

All infrastructure resources for services in this repo are tracked in:
**[hawkbit_resources.yaml](./hawkbit_resources.yaml)**

This file documents every path and resource related to each service across all environments:
ArgoCD, Vault, Terraform, ExternalSecrets, Helm, and Artifactory.

### Rules for hawkbit_resources.yaml

- **Always ask the user before modifying resources tracked in** `hawkbit_resources.yaml`.
- Keep it up to date whenever infrastructure resources are added, removed, or renamed.
- When onboarding a new environment (stg, prd), populate all missing entries before deploying.
- ask to add any new resources before creating them, and update the registry after creation.
