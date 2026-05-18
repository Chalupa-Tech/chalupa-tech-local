apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-storage-subnet
  namespace: grafana
  labels:
    grafana_dashboard: "1"
data:
  storage-subnet.json: |
    {{- .Files.Get "dashboards/storage-subnet.json" | nindent 4 }}
