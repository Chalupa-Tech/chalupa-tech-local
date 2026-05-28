apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-truenas-apps-k3s
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  truenas-apps-k3s.json: |
{{- .Files.Get "dashboards/truenas-apps-k3s.json" | nindent 4 }}
