# .tpl: embeds files/raft-snapshot.sh via .Files.Get (yamllint checks *.yaml only).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: openbao-snapshot
  namespace: openbao
  annotations:
    argocd.argoproj.io/sync-wave: "1"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: openbao-snapshot
  namespace: openbao
  annotations:
    argocd.argoproj.io/sync-wave: "1"
data:
  raft-snapshot.sh: |
{{ .Files.Get "files/raft-snapshot.sh" | indent 4 }}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: openbao-snapshot
  namespace: openbao
  labels:
    app.kubernetes.io/part-of: backups
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  schedule: {{ .Values.snapshot.schedule | quote }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 2
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 900
      template:
        metadata:
          labels:
            app.kubernetes.io/name: openbao-snapshot
        spec:
          serviceAccountName: openbao-snapshot
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 100
            runAsGroup: 1000
            fsGroup: 1000
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: snapshot
              # Same image as the servers (POSIX sh script: the image has no bash/jq).
              image: "{{ .Values.snapshot.image.repository }}:{{ .Values.snapshot.image.tag }}"
              command: ["/bin/sh", "/scripts/raft-snapshot.sh"]
              env:
                - name: BAO_ADDR
                  value: http://openbao-active.openbao.svc.cluster.local:8200
                - name: OUT_DIR
                  value: /backups/openbao
                - name: KEEP
                  value: {{ .Values.snapshot.keep | quote }}
              volumeMounts:
                - name: scripts
                  mountPath: /scripts
                  readOnly: true
                - name: backups
                  mountPath: /backups
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop: ["ALL"]
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
                limits:
                  memory: 256Mi
          volumes:
            - name: scripts
              configMap:
                name: openbao-snapshot
                defaultMode: 0555
            - name: backups
              persistentVolumeClaim:
                claimName: backups-k8s
