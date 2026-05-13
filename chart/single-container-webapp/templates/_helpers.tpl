{{- define "single-container-webapp.name" -}}
{{- .Values.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "single-container-webapp.labels" -}}
app.kubernetes.io/name: {{ include "single-container-webapp.name" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "single-container-webapp.selectorLabels" -}}
app.kubernetes.io/name: {{ include "single-container-webapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
