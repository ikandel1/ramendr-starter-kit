{{/* Primary cluster name: clusterOverrides.primary.name else regionalDR[0].clusters.primary.name else ocp-primary */}}
{{- define "opp.primaryClusterName" -}}
{{- $over := index (.Values.clusterOverrides | default dict) "primary" | default dict -}}
{{- $fromOver := index $over "name" -}}
{{- if $fromOver }}{{ $fromOver }}{{- else if and .Values.regionalDR (index .Values.regionalDR 0) }}{{ (index .Values.regionalDR 0).clusters.primary.name | default "ocp-primary" }}{{- else }}ocp-primary{{ end -}}
{{- end -}}

{{/* Secondary cluster name */}}
{{- define "opp.secondaryClusterName" -}}
{{- $over := index (.Values.clusterOverrides | default dict) "secondary" | default dict -}}
{{- $fromOver := index $over "name" -}}
{{- if $fromOver }}{{ $fromOver }}{{- else if and .Values.regionalDR (index .Values.regionalDR 0) }}{{ (index .Values.regionalDR 0).clusters.secondary.name | default "ocp-secondary" }}{{- else }}ocp-secondary{{ end -}}
{{- end -}}
