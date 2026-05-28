apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-truenas-disks
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  truenas-disks.json: |
{{- .Files.Get "dashboards/truenas-disks.json" | nindent 4 }}
