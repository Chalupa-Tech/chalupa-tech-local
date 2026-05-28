apiVersion: v1
kind: ConfigMap
metadata:
  name: truenas-exporter-mapping
  namespace: truenas-exporter
  annotations:
    # Apply before the Deployment (sync-wave 0) so the configmap exists
    # when the pod's volume mount resolves.
    argocd.argoproj.io/sync-wave: "0"
data:
  graphite_mapping.conf: |
{{ .Files.Get "files/graphite_mapping.conf" | indent 4 }}
