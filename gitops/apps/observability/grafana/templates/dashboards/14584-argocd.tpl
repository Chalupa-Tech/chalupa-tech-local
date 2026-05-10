apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-14584-argocd
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  argocd.json: |
{{- .Files.Get "dashboards/14584-argocd.json" | nindent 4 }}
