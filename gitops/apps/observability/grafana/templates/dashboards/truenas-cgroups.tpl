apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-truenas-cgroups
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  truenas-cgroups.json: |
{{- .Files.Get "dashboards/truenas-cgroups.json" | nindent 4 }}
