# OCP Virtualization Windows VM demo

## Create windows disk from iso

Based on [this blog post](https://developers.redhat.com/articles/2024/09/09/create-windows-golden-image-openshift-virtualization?source=sso#hands_on_openshift_virtualization_windows_uefi_installer_pipeline).

### Prerequisite

Grant privileges for service account in given namespace.

```bash
oc adm policy add-scc-to-user anyuid -z pipeline -n vmexample
```

### Setup

```bash
oc apply ./pipelineRun/windows2k22-installer-run.yaml
```
