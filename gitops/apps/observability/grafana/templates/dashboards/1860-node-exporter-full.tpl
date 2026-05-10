apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-1860-node-exporter-full
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  node-exporter-full.json: |
{{- .Files.Get "dashboards/1860-node-exporter-full.json" | nindent 4 }}
