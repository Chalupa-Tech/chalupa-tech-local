apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-vmagent
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  vmagent.json: |
    {{- .Files.Get "dashboards/vmagent.json" | nindent 4 }}
