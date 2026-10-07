{{- define "booking.keyVaultVolume" -}}
{{- if and .Values.keyVault.enabled (not .Values.sqlserver.enabled) }}
- name: key-vault
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: true
    volumeAttributes:
      secretProviderClass: {{ .Release.Name }}-key-vault
{{- end }}
{{- end }}

{{- define "booking.keyVaultMount" -}}
{{- if and .Values.keyVault.enabled (not .Values.sqlserver.enabled) }}
- name: key-vault
  mountPath: /mnt/key-vault
  readOnly: true
{{- end }}
{{- end }}
