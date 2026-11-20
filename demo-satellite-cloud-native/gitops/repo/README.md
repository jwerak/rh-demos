# rhel-fleet

Single source of truth for the RHEL fleet and its Satellite configuration.
Every change is a pull request; `main` is what runs.

| Path | Applied by | What it controls |
|---|---|---|
| `fleet/<env>/<server>.yaml` | Argo CD app `rhel-fleet` | RHEL VMs on OpenShift Virtualization (add file = new server, delete file = decommission) |
| `satellite/releases.yml` | Argo CD app `satellite-config` -> Ansible job | Which content view version Dev / QA / Prod serve (promotion, rollback) |
| `satellite/structure.yml` | same job | Lifecycle environments, content views, activation keys, host groups, patch waves, RBAC |
| `templates/vm.yaml.j2` | humans, AAP | The one VM template every request is rendered from |
| `aap/` | Ansible Automation Platform | Self-service survey that opens the pull request for you |

No secrets live here. Cloud-init, Satellite credentials and registration
tokens are created in the cluster only.

## Common changes

- **New server:** add `fleet/<env>/<name>.yaml` rendered from the template (or run the AAP template *Request RHEL server*).
- **Promote:** raise a version in `satellite/releases.yml`, Dev first, then QA, then Prod.
- **Roll back:** revert the commit that promoted.
- **New patch wave or host group:** edit `satellite/structure.yml`.
