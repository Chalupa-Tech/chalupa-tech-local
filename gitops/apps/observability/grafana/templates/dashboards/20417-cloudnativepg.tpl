apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-20417-cloudnativepg
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  cloudnativepg.json: |
{{- .Files.Get "dashboards/20417-cloudnativepg.json" | nindent 4 }}
