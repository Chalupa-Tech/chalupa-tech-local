apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-12693-vmagent
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  vmagent.json: |
{{- .Files.Get "dashboards/12693-vmagent.json" | nindent 4 }}
