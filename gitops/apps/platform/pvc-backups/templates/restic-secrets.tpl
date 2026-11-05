# One restic config Secret per source (VolSync wants RESTIC_REPOSITORY and
# RESTIC_PASSWORD in the same Secret). The password comes from OpenBao via
# ESO; the repository URL is the shared REST server + <namespace>-<pvc>.
{{- range .Values.sources }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: restic-{{ .pvc }}
  namespace: {{ .namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao
  target:
    name: restic-{{ .pvc }}
    creationPolicy: Owner
    template:
      data:
        RESTIC_REPOSITORY: {{ printf "%s/%s-%s" $.Values.restic.restUrl .namespace .pvc | quote }}
        RESTIC_PASSWORD: "{{ `{{ .password }}` }}"
  data:
    - secretKey: password
      remoteRef:
        key: {{ $.Values.restic.passwordKey }}
        property: {{ $.Values.restic.passwordProperty }}
{{- end }}
