apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-arrs-overview
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  arrs-overview.json: |
    {{- .Files.Get "dashboards/arrs-overview.json" | nindent 4 }}
