# Hawkbit Update Server

## Introduction

[Eclipse hawkBit™](https://www.eclipse.org/hawkbit/) is a domain independent back-end framework for rolling out software updates to constrained edge devices as well as more powerful controllers and gateways connected to IP based networking infrastructure.

This chart uses hawkbit/hawkbit-update-server container to run Hawkbit update server inside Kubernetes.

## Prerequisites

- Has been tested on Kubernetes 1.11+

## Installing the Chart

To install the chart with the release name `eclipse-hawkbit`, run the following command:

```bash
helm repo add eclipse-iot https://eclipse.org/packages/charts
helm repo update
helm install eclipse-hawkbit eclipse-iot/hawkbit
```

## Uninstalling the Chart

To uninstall/delete the `eclipse-hawkbit` deployment:

```bash
helm delete eclipse-hawkbit
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

> **Tip**: To completely remove the release, run `helm delete --purge eclipse-hawkbit`

## Configuration

Please view the `values.yaml` for the list of possible configuration values with its documentation.

Specify each parameter using the `--set key=value[,key=value]` argument to `helm install`. For example:

```bash
helm install eclipse-hawkbit eclipse-iot/hawkbit --set podDisruptionBudget.enabled=true
```

Alternatively, a YAML file that specifies the values for the parameters can be provided while installing the chart.

### Database URL parameters

When `externalDatabase.url` is empty, the JDBC URL is built from `externalDatabase.host`, `port` and `database`, with `externalDatabase.urlParams` appended as a query string. `externalDatabase.migrateUrlParams` is overlaid on `urlParams` for the db-migrate Job, so the Job can use different connection parameters.

### db-migrate Job naming

With `job.migrate.skipIfUnchanged`, the Job is named `<fullname>-db-migrate-<appVersion>-<hash>`, where the hash covers the Job spec (including `image.tag`). The finished Job is kept and reused while the spec is unchanged; any change creates a new Job and re-runs the migration. Old Jobs are not removed.

### ServiceAccounts for the db-migrate hook

Set `serviceAccount.preSync: true` to create the ServiceAccounts as ArgoCD PreSync hooks, so they exist before the db-migrate Job runs.

### DDI TLS proxy

`ddiProxy.enabled=true` deploys an nginx proxy in front of the DDI service. It terminates TLS, optionally verifies client certificates (`ddiProxy.mtls.verifyClient`), and forwards the verified client CN and an optional issuer hash as headers. Provide the server TLS secret with `ddiProxy.tls.secretName` (existing Secret), `ddiProxy.tls.externalSecret` (an `externalSecrets.secrets` entry) or `ddiProxy.tls.certificate` and `key` (the chart creates it) and, for mTLS, the client CA bundle as `ddiProxy.mtls.clientCa.certificate` (the chart creates the ConfigMap, named by `configMapName` or `<fullname>-ddi-proxy-ca`) or the name of an existing ConfigMap in `configMapName`. One of the two is required unless `verifyClient` is `off`. Expose it with `ddiProxy.service` (type, `loadBalancerClass` and annotations). Set `ddiProxy.proxyProtocol` when the load balancer sends the PROXY protocol.

### Extra objects

`extraObjects` renders additional manifests with the release, for example ConfigMaps that must exist before the db-migrate Job.
