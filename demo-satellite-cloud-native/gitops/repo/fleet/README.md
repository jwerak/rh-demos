# fleet

One file per server: `fleet/<env>/<server>.yaml`, rendered from `templates/vm.yaml.j2`.

Argo CD (`rhel-fleet`) syncs every `*.yaml` below this directory with
auto-sync, prune and self-heal: a merged file becomes a running VM, a deleted
file removes it, a VM deleted by hand comes back.

Removing a VM does not delete its host record in Satellite; that is a separate
decommission step (Hosts -> All Hosts -> Delete, or `hammer host delete`).
