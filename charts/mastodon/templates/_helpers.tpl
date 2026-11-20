{{- define "mastodon.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mastodon.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "mastodon.labels" -}}
{{ include "mastodon.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "mastodon.webHost" -}}
{{- .Values.mastodon.webDomain | default .Values.mastodon.localDomain -}}
{{- end -}}

{{- define "mastodon.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default (printf "v%s" .Chart.AppVersion) }}
{{- end -}}
{{- end -}}

{{- define "mastodon.validate" -}}
{{- $_ := required "mastodon.localDomain is required" .Values.mastodon.localDomain -}}
{{- $_ := required "mastodon.existingSecret is required (see the chart README)" .Values.mastodon.existingSecret -}}
{{- $_ := required "postgresql.host is required" .Values.postgresql.host -}}
{{- $_ := required "redis.host is required" .Values.redis.host -}}
{{- if .Values.s3.enabled -}}
{{- $_ := required "s3.bucket is required when s3.enabled" .Values.s3.bucket -}}
{{- end -}}
{{- if ne (int .Values.sidekiq.replicas) 1 -}}
{{- fail "sidekiq.replicas must be 1: it runs the scheduler queue, which only one process may run. Raise sidekiq.concurrency instead." -}}
{{- end -}}
{{- if and .Values.metrics.podMonitor.enabled (not .Values.metrics.enabled) -}}
{{- fail "metrics.podMonitor.enabled needs metrics.enabled" -}}
{{- end -}}
{{- if and .Values.httpRoute.enabled (not .Values.httpRoute.parentRefs) -}}
{{- fail "httpRoute.parentRefs is required when httpRoute.enabled" -}}
{{- end -}}
{{- end -}}

{{/* Non-secret configuration; secrets come from mastodon.existingSecret. */}}
{{- define "mastodon.env" -}}
- name: LOCAL_DOMAIN
  value: {{ .Values.mastodon.localDomain | quote }}
{{- with .Values.mastodon.webDomain }}
- name: WEB_DOMAIN
  value: {{ . | quote }}
{{- end }}
- name: DB_HOST
  value: {{ .Values.postgresql.host | quote }}
- name: DB_PORT
  value: {{ .Values.postgresql.port | quote }}
- name: DB_NAME
  value: {{ .Values.postgresql.database | quote }}
- name: DB_USER
  value: {{ .Values.postgresql.username | quote }}
- name: DB_SSLMODE
  value: {{ .Values.postgresql.sslMode | quote }}
- name: REDIS_HOST
  value: {{ .Values.redis.host | quote }}
- name: REDIS_PORT
  value: {{ .Values.redis.port | quote }}
{{- if .Values.s3.enabled }}
- name: S3_ENABLED
  value: "true"
- name: S3_BUCKET
  value: {{ .Values.s3.bucket | quote }}
- name: S3_REGION
  value: {{ .Values.s3.region | quote }}
{{- with .Values.s3.endpoint }}
- name: S3_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- with .Values.s3.aliasHost }}
- name: S3_ALIAS_HOST
  value: {{ . | quote }}
{{- end }}
{{- end }}
{{- range $name, $value := .Values.mastodon.extraEnv }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- end -}}

{{/* Container fields shared by every Mastodon container. Takes (dict "root" $ "env" <component env map>). */}}
{{- define "mastodon.container" -}}
image: {{ include "mastodon.image" .root }}
imagePullPolicy: {{ .root.Values.image.pullPolicy }}
env:
  {{- include "mastodon.env" .root | nindent 2 }}
  {{- range $name, $value := .env }}
  - name: {{ $name }}
    value: {{ $value | quote }}
  {{- end }}
  # Made by the tmpdir init container (see mastodon.pod).
  - name: TMPDIR
    value: /tmp/tmp
  - name: HOME
    value: /tmp/home
envFrom:
  - secretRef:
      name: {{ .root.Values.mastodon.existingSecret }}
securityContext:
  {{- include "mastodon.containerSecurityContext" . | nindent 2 }}
volumeMounts:
  - name: tmp
    mountPath: /tmp
  {{- if .uploads }}
  - name: uploads
    mountPath: /tmp/mastodon/public-system
  {{- end }}
{{- end -}}

{{- define "mastodon.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
privileged: false
capabilities:
  drop: [ALL]
{{- end -}}

{{/* Pod fields shared by every Mastodon pod. Takes (dict "root" $ "uploads" <bool>). */}}
{{- define "mastodon.pod" -}}
automountServiceAccountToken: false
# Service links would inject e.g. REDIS_PORT=tcp://..., which Mastodon reads.
enableServiceLinks: false
{{- with .root.Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
securityContext:
  runAsNonRoot: true
  runAsUser: 991
  runAsGroup: 991
  fsGroup: 991
  fsGroupChangePolicy: OnRootMismatch
  seccompProfile:
    type: RuntimeDefault
{{- with .root.Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .root.Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .root.Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
# An emptyDir is world-writable without the sticky bit, which Ruby refuses
# as a temporary directory; HOME and TMPDIR are private directories in it.
initContainers:
  - name: tmpdir
    image: {{ include "mastodon.image" .root }}
    imagePullPolicy: {{ .root.Values.image.pullPolicy }}
    args: [ruby, -e, 'require "fileutils"; FileUtils.mkdir_p(%w[/tmp/tmp /tmp/home], mode: 0o700)']
    securityContext:
      {{- include "mastodon.containerSecurityContext" . | nindent 6 }}
    volumeMounts:
      - name: tmp
        mountPath: /tmp
volumes:
  - name: tmp
    emptyDir:
      sizeLimit: {{ .root.Values.tmpSizeLimit }}
  {{- if .uploads }}
  - name: uploads
    persistentVolumeClaim:
      claimName: {{ .root.Values.persistence.existingClaim | default (printf "%s-uploads" (include "mastodon.fullname" .root)) }}
  {{- end }}
{{- end -}}

{{/*
Prometheus exporter environment, merged into web's and sidekiq's. Sidekiq
serves /metrics itself ("local"). Puma's in-process server would only see
the master's metrics, not its forked workers', so web sends them to a
collector sidecar on 127.0.0.1:9394 instead.
*/}}
{{- define "mastodon.metricsEnv" -}}
{{- if .root.Values.metrics.enabled }}
MASTODON_PROMETHEUS_EXPORTER_ENABLED: "true"
{{- if .local }}
MASTODON_PROMETHEUS_EXPORTER_LOCAL: "true"
MASTODON_PROMETHEUS_EXPORTER_HOST: "0.0.0.0"
MASTODON_PROMETHEUS_EXPORTER_PORT: "9394"
{{- else }}
PROMETHEUS_EXPORTER_HOST: "127.0.0.1"
PROMETHEUS_EXPORTER_PORT: "9394"
{{- end }}
{{- end }}
{{- end -}}

{{- define "mastodon.uploads" -}}
{{- if not .Values.s3.enabled }}true{{ end -}}
{{- end -}}
