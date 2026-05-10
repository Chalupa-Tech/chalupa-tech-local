apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-17346-traefik-2
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  traefik-2.json: |
{{- .Files.Get "dashboards/17346-traefik-2.json" | nindent 4 }}
