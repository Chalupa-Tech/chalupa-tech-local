apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-truenas-overview
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  truenas-overview.json: |
{{- .Files.Get "dashboards/truenas-overview.json" | nindent 4 }}
