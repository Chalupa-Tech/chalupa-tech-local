apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-tautulli-bandwidth
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  tautulli-bandwidth.json: |
{{- .Files.Get "dashboards/tautulli-bandwidth.json" | nindent 4 }}
