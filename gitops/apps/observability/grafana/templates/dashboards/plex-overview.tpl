apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-plex-overview
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  plex-overview.json: |
    {{- .Files.Get "dashboards/plex-overview.json" | nindent 4 }}
