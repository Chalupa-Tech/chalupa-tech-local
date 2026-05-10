apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-13770-kubernetes-views-global
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  kubernetes-views-global.json: |
{{- .Files.Get "dashboards/13770-kubernetes-views-global.json" | nindent 4 }}
