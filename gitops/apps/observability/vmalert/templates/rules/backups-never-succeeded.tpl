# Go-templated (range over values), so .tpl like the grafana dashboards:
# yamllint checks *.yaml only, Helm renders every file under templates/.
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMRule
metadata:
  name: backups-never-succeeded
  namespace: vm-system
  annotations:
    argocd.argoproj.io/sync-wave: "30"
spec:
  groups:
    - name: backups-never-succeeded
      rules:
        # One rule per expected guest (values: backups.expectedVmids): fires
        # from the moment the rule exists until that guest's first successful
        # vzdump, and again if its series ever disappears. This is the alert
        # that would have caught the eight silent months.
{{- range .Values.backups.expectedVmids }}
        - alert: ProxmoxBackupNeverSucceeded
          expr: 'absent(pve_backup_last_success_timestamp{job="proxmox-host",vmid="{{ . }}"})'
          for: 2h
          labels:
            severity: warning
            vmid: "{{ . }}"
          annotations:
            summary: 'No successful Proxmox backup recorded for VMID {{ . }}'
            description: 'pve_backup_last_success_timestamp for VMID {{ . }} is absent — the nightly job has not succeeded for this guest since the hook was installed, or the metric pipeline is broken.'
{{- end }}
