#!/usr/bin/env bash
# Wait until the Silverblue guest has a user session, then run the fusermount repro.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="fedora-silverblue-44"
key="${root}/output/ssh/id_ed25519"
guest_script="${root}/scripts/guest-repro.sh"

if [[ ! -f "${key}" ]]; then
	echo "error: missing ${key}. Run ./scripts/run-libvirt.sh first." >&2
	exit 1
fi

guest_ip() {
	sudo virsh domifaddr "${name}" --source lease 2>/dev/null \
		| awk '/ipv4/ {print $4}' \
		| head -n1 \
		| cut -d/ -f1
}

echo "Waiting for ${name} DHCP lease and SSH (install reboot can take a while)."
ip=""
for _ in $(seq 1 120); do
	ip="$(guest_ip || true)"
	if [[ -n "${ip}" ]] && ssh -i "${key}" \
		-o BatchMode=yes \
		-o StrictHostKeyChecking=accept-new \
		-o ConnectTimeout=5 \
		"demo@${ip}" true 2>/dev/null; then
		break
	fi
	ip=""
	sleep 10
done

if [[ -z "${ip}" ]]; then
	echo "error: ${name} did not accept SSH as demo@<dhcp> within 20 minutes." >&2
	exit 1
fi

echo "Waiting for the GDM autologin session bus."
ready=0
for _ in $(seq 1 60); do
	if ssh -i "${key}" -o BatchMode=yes -o ConnectTimeout=5 "demo@${ip}" \
		'test -S "/run/user/$(id -u)/bus"'; then
		ready=1
		break
	fi
	sleep 5
done
if ((ready == 0)); then
	echo "error: SSH works, but /run/user/\$(id -u)/bus never appeared." >&2
	exit 1
fi

echo "Running fusermount repro on demo@${ip}"
ssh -i "${key}" -o BatchMode=yes "demo@${ip}" 'bash -s' < "${guest_script}"
scp -i "${key}" -o BatchMode=yes "demo@${ip}:fusermount-repro.log" "${root}/output/fusermount-repro.log"
echo "Saved ${root}/output/fusermount-repro.log"
