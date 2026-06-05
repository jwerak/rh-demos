# CLAUDE.md

## Overview

Windows golden image creation using Tekton pipelines on OpenShift Virtualization. Runs the `windows-efi-installer` pipeline from the Red Hat pipelines catalog to produce a bootable Windows disk from an ISO.

## Structure

- `pipelineRun/windows2k22-installer-run.yaml` - PipelineRun manifest referencing the `windows-efi-installer` pipeline (v4.20.4 from redhat-pipelines hub)

## Prerequisites

- OpenShift cluster with OpenShift Virtualization and OpenShift Pipelines installed
- Windows ISO download URL (obtain from Microsoft)
- EULA acceptance (set `acceptEula: true` in the PipelineRun)
- Grant SCC to pipeline SA: `oc adm policy add-scc-to-user anyuid -z pipeline -n vmexample`

## Commands

```bash
# Grant required privileges
oc adm policy add-scc-to-user anyuid -z pipeline -n vmexample

# Update WIN_IMAGE_DOWNLOAD_URL and acceptEula in the manifest, then apply
oc apply -f pipelineRun/windows2k22-installer-run.yaml
```

## Notes

- The PipelineRun uses `generateName` so each apply creates a new run
- Pipeline resolves from the Tekton Hub (`resolver: hub`, catalog: `redhat-pipelines`)
- The pod runs as user/group 107 (fsGroup/runAsUser in podTemplate)
