# Unattended Fedora Silverblue 44 install from the official ostree ISO.
# Injected into the installer initrd by scripts/run-libvirt.sh.
# __DEMO_SSH_PUBKEY__ is replaced with output/ssh/id_ed25519.pub.
#version=DEVEL
text --non-interactive
cdrom
lang cs_CZ.UTF-8
keyboard cz
timezone Europe/Prague --utc
network --bootproto=dhcp --device=link --activate --onboot=yes --hostname=silverblue
rootpw --lock
user --name=demo --password=demo --plaintext --groups=wheel --homedir=/var/home/demo
firewall --enabled --service=ssh
selinux --enforcing
firstboot --disable
services --enabled=sshd
zerombr
ignoredisk --only-use=vda
clearpart --all --initlabel
autopart --type=btrfs
bootloader --append="rhgb quiet"
ostreesetup --osname="fedora" --remote="fedora" --url="file:///ostree/repo" --ref="fedora/44/x86_64/silverblue" --nogpg
reboot --eject

%post --erroronfail --log=/var/log/silverblue-ks-post.log
set -eux

if ! id demo >/dev/null 2>&1; then
	useradd -m -d /var/home/demo -G wheel demo
	echo 'demo:demo' | chpasswd
fi

install -d -m 0700 -o demo -g demo /var/home/demo/.ssh
cat > /var/home/demo/.ssh/authorized_keys <<'EOF'
__DEMO_SSH_PUBKEY__
EOF
chown demo:demo /var/home/demo/.ssh/authorized_keys
chmod 0600 /var/home/demo/.ssh/authorized_keys
restorecon -R /var/home/demo/.ssh || true

install -d -m 0755 -o demo -g demo /var/home/demo/.config
install -m 0644 -o demo -g demo /dev/null /var/home/demo/.config/gnome-initial-setup-done

mkdir -p /etc/gdm
cat > /etc/gdm/custom.conf <<'EOF'
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=demo
EOF

mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/99-demo.conf
ln -sfn /usr/lib/systemd/system/sshd.service /etc/systemd/system/multi-user.target.wants/sshd.service
ln -sfn /usr/lib/systemd/system/graphical.target /etc/systemd/system/default.target
%end
