# Go-templated (range over values) -> .tpl, like the grafana dashboards;
# yamllint checks *.yaml only, Helm renders every file under templates/.
{{- range .Values.sources }}
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: {{ .pvc }}
  namespace: {{ .namespace }}
  labels:
    app.kubernetes.io/managed-by: argocd
    app.kubernetes.io/part-of: backups
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  sourcePVC: {{ .pvc }}
  trigger:
    schedule: {{ .schedule | quote }}
  restic:
    repository: restic-{{ .pvc }}
    copyMethod: Direct
    pruneIntervalDays: {{ $.Values.restic.pruneIntervalDays }}
    cacheCapacity: {{ $.Values.restic.cacheCapacity }}
    retain:
      hourly: {{ $.Values.restic.retain.hourly }}
      daily: {{ $.Values.restic.retain.daily }}
      weekly: {{ $.Values.restic.retain.weekly }}
    moverSecurityContext:
      runAsUser: {{ .runAsUser }}
      runAsGroup: {{ .runAsGroup }}
      fsGroup: {{ .runAsGroup }}
{{- end }}
