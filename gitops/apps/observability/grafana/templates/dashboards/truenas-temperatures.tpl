apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-truenas-temperatures
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  truenas-temperatures.json: |
{{- .Files.Get "dashboards/truenas-temperatures.json" | nindent 4 }}
