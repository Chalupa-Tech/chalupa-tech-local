apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-12683-victoriametrics-single
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  victoriametrics-single.json: |
{{- .Files.Get "dashboards/12683-victoriametrics-single.json" | nindent 4 }}
