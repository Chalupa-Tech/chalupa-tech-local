# .tpl: embeds files/pg-dump.sh via .Files.Get (yamllint checks *.yaml only).
apiVersion: v1
kind: ConfigMap
metadata:
  name: arrs-pg-dump
  namespace: media
  annotations:
    argocd.argoproj.io/sync-wave: "1"
data:
  pg-dump.sh: |
{{ .Files.Get "files/pg-dump.sh" | indent 4 }}
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: arrs-pg-dump
  namespace: media
  labels:
    app.kubernetes.io/part-of: backups
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  schedule: {{ .Values.dump.schedule | quote }}
  timeZone: {{ .Values.dump.timeZone }}
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 3600
      template:
        metadata:
          labels:
            app.kubernetes.io/name: arrs-pg-dump
        spec:
          restartPolicy: Never
          securityContext:
            runAsNonRoot: true
            runAsUser: 26
            runAsGroup: 26
            fsGroup: 26
            seccompProfile:
              type: RuntimeDefault
          containers:
            - name: pg-dump
              # Same image as the cluster: matching pg_dumpall version, zstd present.
              image: {{ .Values.cluster.imageName }}
              command: ["/bin/bash", "/scripts/pg-dump.sh"]
              env:
                - name: PGHOST
                  value: arrs-pg-rw
                - name: OUT_DIR
                  value: /backups/postgres
                - name: KEEP
                  value: {{ .Values.dump.keep | quote }}
                - name: PGUSER
                  valueFrom:
                    secretKeyRef:
                      name: arrs-pg-superuser
                      key: username
                - name: PGPASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: arrs-pg-superuser
                      key: password
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
                  cpu: 100m
                  memory: 128Mi
                limits:
                  memory: 1Gi
          volumes:
            - name: scripts
              configMap:
                name: arrs-pg-dump
                defaultMode: 0555
            - name: backups
              persistentVolumeClaim:
                claimName: backups-k8s
