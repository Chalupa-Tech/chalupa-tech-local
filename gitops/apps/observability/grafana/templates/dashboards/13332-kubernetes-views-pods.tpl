apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-13332-kubernetes-views-pods
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  kubernetes-views-pods.json: |
{{- .Files.Get "dashboards/13332-kubernetes-views-pods.json" | nindent 4 }}
