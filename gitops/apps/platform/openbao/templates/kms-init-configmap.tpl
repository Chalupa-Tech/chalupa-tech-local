# Init-container script for the OpenBao server pods (files/kms-init.sh):
# installs the pinned OCI KMS seal plugin and writes /openbao/kms/seal.hcl.
apiVersion: v1
kind: ConfigMap
metadata:
  name: openbao-kms-init
  namespace: openbao
data:
  kms-init.sh: |
{{ .Files.Get "files/kms-init.sh" | indent 4 }}
