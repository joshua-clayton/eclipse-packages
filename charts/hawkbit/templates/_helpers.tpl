{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "hawkbit.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "hawkbit.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "hawkbit.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "hawkbit.labels" -}}
app.kubernetes.io/name: {{ include "hawkbit.name" . }}
helm.sh/chart: {{ include "hawkbit.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Return the appropriate apiVersion for ingress.
*/}}
{{- define "hawkbit.ingressAPIVersion" -}}
{{- if .Capabilities.APIVersions.Has "networking.k8s.io/v1/Ingress" -}}
{{- print "networking.k8s.io/v1" -}}
{{- else -}}
{{- print "networking.k8s.io/v1beta1" -}}
{{- end -}}
{{- end -}}

{{/*
Return the secret with the Hawkbit credentials.
*/}}
{{- define "hawkbit.secretName" -}}
  {{- if .Values.auth.existingSecret -}}
    {{ print (tpl .Values.auth.existingSecret $) -}}
  {{- else -}}
    {{ printf "%s" (include "hawkbit.fullname" .) -}}
  {{- end -}}
{{- end -}}

{{- define "hawkbit.userCredentialsSecretName" -}}
  {{- if .Values.auth.existingSecret -}}
    {{- .Values.auth.existingSecret -}}
  {{- else -}}
    {{- printf "%s-user" (include "hawkbit.fullname" .) -}}
  {{- end -}}
{{- end -}}

{{- define "hawkbit.dbCredentialsSecretName" -}}
  {{- if .Values.externalDatabase.existingSecret -}}
    {{- .Values.externalDatabase.existingSecret -}}
  {{- else -}}
    {{- printf "%s-db" (include "hawkbit.fullname" .) -}}
  {{- end -}}
{{- end -}}

{{- define "hawkbit.rabbitmqCredentialsSecretName" -}}
  {{- if .Values.rabbitmq.credentialsSecret -}}
    {{- .Values.rabbitmq.credentialsSecret -}}
  {{- else -}}
    {{- printf "%s-rabbitmq-creds" (include "hawkbit.fullname" .) -}}
  {{- end -}}
{{- end -}}

{{/*
Database helpers — switch between externalDatabase and the bundled mariadb subchart.
*/}}

{{- define "hawkbit.database.url" -}}
  {{- if .Values.externalDatabase.url -}}
    {{- .Values.externalDatabase.url -}}
  {{- else if and .Values.externalDatabase.host (eq (.Values.externalDatabase.type | default "mariadb") "postgresql") -}}
    {{- printf "jdbc:postgresql://%s:%v/%s" .Values.externalDatabase.host (.Values.externalDatabase.port | default 5432) (.Values.externalDatabase.database | default "hawkbit") -}}
  {{- else if .Values.externalDatabase.host -}}
    {{- printf "jdbc:mariadb://%s:%v/%s" .Values.externalDatabase.host (.Values.externalDatabase.port | default 3306) (.Values.externalDatabase.database | default "hawkbit") -}}
  {{- else if .Values.mariadb.enabled -}}
    {{- printf "jdbc:mariadb://%s-mariadb:3306/%s" (include "hawkbit.fullname" .) .Values.mariadb.auth.database -}}
  {{- else -}}
    {{- fail "Either externalDatabase.host or mariadb.enabled must be set" -}}
  {{- end -}}
{{- end -}}

{{/*
JDBC URL for the db-migrate Job. Falls back to hawkbit.database.url when
externalDatabase.migrateUrl is unset.
*/}}
{{- define "hawkbit.database.migrateUrl" -}}
  {{- if .Values.externalDatabase.migrateUrl -}}
    {{- .Values.externalDatabase.migrateUrl -}}
  {{- else -}}
    {{- include "hawkbit.database.url" . -}}
  {{- end -}}
{{- end -}}

{{- define "hawkbit.database.user" -}}
  {{- if .Values.externalDatabase.user -}}
    {{- .Values.externalDatabase.user -}}
  {{- else if .Values.mariadb.enabled -}}
    {{- "root" -}}
  {{- else -}}
    {{- fail "externalDatabase.user is required when mariadb.enabled=false" -}}
  {{- end -}}
{{- end -}}

{{- define "hawkbit.database.secretName" -}}
  {{- if .Values.externalDatabase.existingSecret -}}
    {{- .Values.externalDatabase.existingSecret -}}
  {{- else if .Values.mariadb.enabled -}}
    {{- include "mariadb.secretName" .Subcharts.mariadb -}}
  {{- else -}}
    {{- printf "%s-external-db" (include "hawkbit.fullname" .) -}}
  {{- end -}}
{{- end -}}

{{- define "hawkbit.database.secretPasswordKey" -}}
  {{- if .Values.externalDatabase.existingSecretPasswordKey -}}
    {{- .Values.externalDatabase.existingSecretPasswordKey -}}
  {{- else if .Values.mariadb.enabled -}}
    {{- "mariadb-root-password" -}}
  {{- else -}}
    {{- "password" -}}
  {{- end -}}
{{- end -}}

{{- define "hawkbit.database.secretUsernameKey" -}}
  {{- if .Values.externalDatabase.existingSecretUsernameKey -}}
    {{- .Values.externalDatabase.existingSecretUsernameKey -}}
  {{- end -}}
{{- end -}}

{{- define "hawkbit.spring.profiles" -}}
  {{- if .Values.spring.profiles -}}
    {{- .Values.spring.profiles -}}
  {{- else if eq (.Values.externalDatabase.type | default "mariadb") "postgresql" -}}
    {{- "postgresql" -}}
  {{- else -}}
    {{- "mysql" -}}
  {{- end -}}
{{- end -}}

{{/*
DB credential env vars for the mariadb case, injected via secretKeyRef.
Takes a dict: {root: $, user: <override username, optional>}. "user" falls
back to externalDatabase.user when unset; used by the db-migrate Job to
connect as a distinct DB user (see externalDatabase.migrateUser).
*/}}
{{- define "hawkbit.dbCredentialsEnvFor" -}}
{{- $root := .root -}}
{{- $user := .user | default $root.Values.externalDatabase.user -}}
{{- if $root.Values.mariadb.enabled }}
- name: SPRING_DATASOURCE_USERNAME
  value: "root"
- name: SPRING_DATASOURCE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "mariadb.secretName" $root.Subcharts.mariadb }}
      key: {{ $root.Values.mariadb.auth.secretKeys.rootPasswordKey | default "mysql-root-password" }}
{{- else if and (not $root.Values.externalDatabase.existingSecret) $user }}
- name: SPRING_DATASOURCE_USERNAME
  value: {{ $user | quote }}
{{- end }}
{{- end -}}

{{- define "hawkbit.dbCredentialsEnv" -}}
{{- include "hawkbit.dbCredentialsEnvFor" (dict "root" .) -}}
{{- end -}}

{{/*
Gateway token key env var, sourced from an existing secret when
auth.gatewayToken.existingSecret is set. Omitted otherwise (the literal
value, if any, is instead rendered into application-user-credentials.yaml).
*/}}
{{- define "hawkbit.gatewayTokenEnv" -}}
{{- if and .Values.auth.gatewayToken.enabled .Values.auth.gatewayToken.existingSecret }}
- name: HAWKBIT_SERVER_DDI_SECURITY_AUTHENTICATION_GATEWAYTOKEN_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.auth.gatewayToken.existingSecret }}
      key: {{ .Values.auth.gatewayToken.existingSecretKey | default "key" }}
{{- end }}
{{- end -}}

{{/*
Environment variables shared by all hawkbit containers (init and application).
All vars are either used by both or safely ignored by whichever doesn't need them.
Appends .Values.extraEnv (must be a list of k8s env var objects) when set.
*/}}
{{- define "hawkbit.env" -}}
- name: PROFILES
  value: {{ include "hawkbit.spring.profiles" . | quote }}
- name: SPRING_DATASOURCE_URL
  value: {{ include "hawkbit.database.url" . | quote }}
- name: SPRING_FLYWAY_ENABLED
  value: "false"
{{- include "hawkbit.dbCredentialsEnv" . }}
{{- include "hawkbit.gatewayTokenEnv" . }}
{{- if .Values.vaultAgent.enabled }}
- name: SPRING_CONFIG_ADDITIONAL_LOCATION
  value: "optional:file:/vault/secrets/"
{{- end }}
{{- if .Values.fileStorage.enabled }}
- name: ORG_ECLIPSE_HAWKBIT_ARTIFACT_FS_PATH
  value: {{ .Values.fileStorage.mountPath }}
{{- end }}
{{- with .Values.extraEnv }}
{{- if kindIs "slice" . }}
{{- toYaml . | nindent 0 }}
{{- else }}
{{- fail (printf "extraEnv must be a list of env var objects (got %s). See values.yaml for the supported format." (kindOf .)) }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
envFrom items for internal or external database credentials.
Skipped when externalDatabase.mountCredentialsSecret=false — use this when
credentials are provided through an external mechanism (e.g. a sidecar that
injects them as a file read via spring.config.import).
*/}}
{{- define "hawkbit.dbEnvFrom" -}}
{{- if and (not .Values.mariadb.enabled) .Values.externalDatabase.mountCredentialsSecret }}
            - secretRef:
                name: {{ include "hawkbit.dbCredentialsSecretName" . }}
{{- end }}
{{- end -}}

{{/*
TLS/mTLS env vars for a component's serving container.
Takes a dict: {tls: <component's .tls value>, metricsPort: <component's .metricsPort value>}.
mtls (client-cert auth) is only meaningful once tls itself is enabled, so it's nested
under tls rather than a sibling of it. metricsPort, when set, moves actuator health
checks off the TLS-enabled main port so kubelet's plain-HTTP probes keep working;
management.server.ssl is explicitly disabled since Spring Boot otherwise inherits
the main server's SSL config onto the management port too.
*/}}
{{- define "hawkbit.tlsEnv" -}}
{{- $tls := .tls | default dict -}}
{{- if $tls.enabled -}}
- name: SERVER_SSL_ENABLED
  value: "true"
- name: SERVER_SSL_CERTIFICATE
  value: {{ $tls.certFile | quote }}
- name: SERVER_SSL_CERTIFICATE_PRIVATE_KEY
  value: {{ $tls.keyFile | quote }}
{{- $mtls := $tls.mtls | default dict }}
{{- if $mtls.enabled }}
- name: SERVER_SSL_CLIENT_AUTH
  value: {{ $mtls.clientAuth | default "need" | quote }}
- name: SERVER_SSL_TRUST_CERTIFICATE
  value: {{ $mtls.caFile | quote }}
{{- end }}
{{- if .metricsPort }}
- name: MANAGEMENT_SERVER_PORT
  value: {{ .metricsPort | quote }}
- name: MANAGEMENT_SERVER_SSL_ENABLED
  value: "false"
{{- end }}
{{- end }}
{{- end -}}

{{/*
Extra "metrics" containerPort for a component, when metricsPort is set.
Pass a dict: {metricsPort: <component's .metricsPort value>}.
*/}}
{{- define "hawkbit.metricsPort" -}}
{{- if .metricsPort -}}
- name: metrics
  containerPort: {{ .metricsPort }}
  protocol: TCP
{{- end }}
{{- end -}}

{{/*
Which named/numbered port liveness/readiness probes should target: the component's
metricsPort if set, otherwise the default "http" port.
*/}}
{{- define "hawkbit.probePort" -}}
{{- .metricsPort | default "http" -}}
{{- end -}}

{{/*
Merge per-service autoscaling overrides with the shared microservices.autoscaling defaults.
Usage: include "hawkbit.autoscaling" (dict "svc" .Values.microservices.mgmt "defaults" .Values.microservices.autoscaling)
Returns a single autoscaling map with per-service keys taking precedence.
*/}}
{{- define "hawkbit.autoscaling" -}}
{{- $merged := merge (default dict .svc.autoscaling) .defaults -}}
{{- toYaml $merged -}}
{{- end -}}

{{/*
ServiceAccount name for pods. Falls back to the chart's fullname when
serviceAccount.create is true and no name is given.
*/}}
{{- define "hawkbit.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- .Values.serviceAccount.name | default (include "hawkbit.fullname" .) -}}
{{- else -}}
{{- .Values.serviceAccount.name | default "" -}}
{{- end -}}
{{- end -}}

{{/*
ServiceAccount name for the db-migrate Job. Falls back to the main
serviceAccountName when job.serviceAccountName is unset. This chart never
creates this ServiceAccount itself (it's expected to be managed externally,
same as serviceAccount.create: false).
*/}}
{{- define "hawkbit.job.serviceAccountName" -}}
{{- .Values.job.serviceAccountName | default (include "hawkbit.serviceAccountName" .) -}}
{{- end -}}

{{/*
Vault Agent Injector annotations for dynamic DB credential injection.
Renders a Spring Boot .properties file to /vault/secrets/ containing
spring.datasource.username and spring.datasource.password.
Set externalDatabase.mountCredentialsSecret: false alongside this to prevent
the k8s secret envFrom from taking precedence over the injected file.
*/}}
{{- define "hawkbit.vaultAgentAnnotations" -}}
{{- if .Values.vaultAgent.enabled }}
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: {{ .Values.vaultAgent.role | quote }}
vault.hashicorp.com/agent-inject-secret-db.properties: {{ .Values.vaultAgent.dbCredsPath | quote }}
vault.hashicorp.com/agent-inject-template-db.properties: |
  {{`{{- with secret "`}}{{ .Values.vaultAgent.dbCredsPath }}{{`" }}
  spring.datasource.username={{ .Data.username }}
  spring.datasource.password={{ .Data.password }}
  {{- end }}`}}
vault.hashicorp.com/agent-revoke-on-shutdown: "true"
{{- end }}
{{- end -}}
