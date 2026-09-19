{{- define "grainops.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "grainops.fullname" -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels for every object; the component label distinguishes tiers. */}}
{{- define "grainops.labels" -}}
app.kubernetes.io/name: {{ include "grainops.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "grainops.selector" -}}
app.kubernetes.io/name: {{ include "grainops.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "grainops.secretName" -}}
{{- if .Values.secrets.existingSecret -}}{{ .Values.secrets.existingSecret }}{{- else -}}{{ include "grainops.fullname" . }}{{- end -}}
{{- end -}}

{{/*
Environment for anything that talks to the database and Redis. With the
in-cluster Postgres, DATABASE_URL is composed from the password in the
Secret using Kubernetes' $(VAR) expansion; otherwise it is read whole.
*/}}
{{- define "grainops.eventgrainEnv" -}}
{{- if .Values.postgres.enabled }}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "grainops.secretName" . }}
      key: POSTGRES_PASSWORD
- name: DATABASE_URL
  value: postgresql://eventgrain:$(POSTGRES_PASSWORD)@{{ include "grainops.fullname" . }}-postgres:5432/eventgrain
{{- else }}
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ include "grainops.secretName" . }}
      key: DATABASE_URL
{{- end }}
- name: REDIS_URL
  value: redis://{{ include "grainops.fullname" . }}-redis:6379
- name: RETENTION_MONTHS
  value: {{ .Values.eventgrain.retentionMonths | quote }}
- name: PORT
  value: "4200"
{{- end -}}

{{/* Pod-level hardening shared by every workload. */}}
{{- define "grainops.podSecurityContext" -}}
runAsNonRoot: true
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "grainops.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end -}}
