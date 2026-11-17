{{- define "portal-gq.name" -}}portal-gq{{- end -}}
{{- define "portal-gq.labels" -}}
app.kubernetes.io/name: {{ include "portal-gq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}
{{- define "portal-gq.selector" -}}
app.kubernetes.io/name: {{ include "portal-gq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
