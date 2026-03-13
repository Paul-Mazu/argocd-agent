{{/*
Expand the name of the chart.
*/}}
{{- define "argocd-agent-principal.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "argocd-agent-principal.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Base name for Helm-created resources, derived from the release.
*/}}
{{- define "argocd-agent-principal.baseName" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-principal-helm" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Helper to append a suffix to the resource base name.
Usage: {{ include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "metrics") }}
*/}}
{{- define "argocd-agent-principal.resourceName" -}}
{{- $root := .root -}}
{{- $suffix := .suffix | default "" -}}
{{- $base := include "argocd-agent-principal.baseName" $root -}}
{{- if $suffix }}
{{- printf "%s-%s" $base $suffix | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $base }}
{{- end }}
{{- end }}

{{/*
Name for the principal deployment.
*/}}
{{- define "argocd-agent-principal.deploymentName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "") }}
{{- end }}

{{/*
Common resource-specific helpers.
*/}}
{{- define "argocd-agent-principal.paramsConfigMapName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "params") }}
{{- end }}

{{- define "argocd-agent-principal.grpcServiceName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "") }}
{{- end }}

{{- define "argocd-agent-principal.metricsServiceName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "metrics") }}
{{- end }}

{{- define "argocd-agent-principal.healthzServiceName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "healthz") }}
{{- end }}

{{- define "argocd-agent-principal.redisProxyServiceName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "redis-proxy") }}
{{- end }}

{{- define "argocd-agent-principal.resourceProxyServiceName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "resource-proxy") }}
{{- end }}

{{- define "argocd-agent-principal.roleName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "role") }}
{{- end }}

{{- define "argocd-agent-principal.roleBindingName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "rolebinding") }}
{{- end }}

{{- define "argocd-agent-principal.clusterRoleName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "clusterrole") }}
{{- end }}

{{- define "argocd-agent-principal.clusterRoleBindingName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "clusterrolebinding") }}
{{- end }}

{{- define "argocd-agent-principal.userpassSecretName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "userpass") }}
{{- end }}

{{/*
Name for resources used exclusively by Helm tests.
*/}}
{{- define "argocd-agent-principal.testResourceName" -}}
{{- printf "%s-test" (include "argocd-agent-principal.baseName" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "argocd-agent-principal.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "argocd-agent-principal.labels" -}}
helm.sh/chart: {{ include "argocd-agent-principal.chart" . }}
{{ include "argocd-agent-principal.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "argocd-agent-principal.selectorLabels" -}}
app.kubernetes.io/name: argocd-agent-principal
app.kubernetes.io/part-of: argocd-agent
app.kubernetes.io/component: principal
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "argocd-agent-principal.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- if .Values.serviceAccount.name }}
{{- .Values.serviceAccount.name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "sa") }}
{{- end }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Name for the principal service monitor.
*/}}
{{- define "argocd-agent-principal.serviceMonitorName" -}}
{{- include "argocd-agent-principal.resourceName" (dict "root" . "suffix" "servicemonitor") }}
{{- end }}

{{/*
Expand the namespace of the release.
*/}}
{{- define "argocd-agent-principal.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride | trunc 63 | trimSuffix "-" -}}
{{- end }}
