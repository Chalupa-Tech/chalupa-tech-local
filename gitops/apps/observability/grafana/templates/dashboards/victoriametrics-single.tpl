apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-victoriametrics-single
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  victoriametrics-single.json: |
    {{- .Files.Get "dashboards/victoriametrics-single.json" | nindent 4 }}
