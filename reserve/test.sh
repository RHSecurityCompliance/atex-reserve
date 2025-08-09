#!/bin/bash

set -e -x

# always reboot into the same OS entry (unless otherwise overriden)
#
# we're executing efibootmgr here instead of just checking its existence
# because some systems have the binary, but, when run, it fails with:
#   EFI variables are not supported on this system.
if efibootmgr &>/dev/null; then
    current=$(efibootmgr | sed -n 's/^BootCurrent: //p')
    efibootmgr -n "$current"
fi

# no-op on second/third/etc. execution
if [[ $TMT_TEST_RESTART_COUNT && $TMT_TEST_RESTART_COUNT -gt 0 ]]; then
    exec sleep inf
    exit 1
fi

# ------------------------------------------------------------------------------

# remove tmt-related commands
# (if running tmt via 'provision -h connect', tmt will upload its own)
rm -f /usr/local/bin/{tmt,rstrnt,rhts}-*

# ------------------------------------------------------------------------------

if [[ ! -e /run/ostree-booted ]]; then
    # remove useless daemons to free up RAM a bit
    dnf remove -y rng-tools irqbalance

    # clean up packages from extra repos, restoring original vanilla OS (sorta)
    rm -v -f \
        /etc/yum.repos.d/{tag-repository,*beakerlib*,rcmtools,qa-tools}.repo \
        /etc/yum.repos.d/beaker-{client,harness,tasks}.repo
    # downgrade any packages installed/upgraded from the extra package repos
    function list_foreign_rpms {
        dnf list --installed \
        | grep -e @koji-override -e @testing-farm -e @epel -e @copr: -e @rcmtools -e '<unknown>$' \
        | sed 's/ .*//'
    }
    rpms=$(list_foreign_rpms)
    [[ $rpms ]] && dnf downgrade -y --skip-broken $rpms || true
    rpms=$(list_foreign_rpms)
    [[ $rpms ]] && dnf remove -y --noautoremove $rpms
    dnf clean all
fi

# ------------------------------------------------------------------------------

# replace fedora mirrormanager-based repositories with primary/master ones,
# which tend to be a lot more reliable
# - this is to avoid checksum errors that very commonly pop up on mirrormanager
#   on all mirrors (so trying different mirrors doesn't help and dnf eventually
#   fails):
#     Downloading successful, but checksum doesn't match. Calculated: 1abb62...
#     Expected: a91641...
function mkrepo {
    echo "[$1]"
    echo "name=$1"
    echo "baseurl=$2"
    [[ $GPGKEY ]] && echo "gpgkey=$GPGKEY"
    echo "gpgcheck=1"
    echo "enabled=${3:-1}"
}
os_id=$(. /etc/os-release; echo "$ID")
os_id_version=$(. /etc/os-release; echo "$ID:$VERSION_ID")
# 8 is on vault/archive, 10 is currently broken
if [[ $os_id_version == centos:9 ]]; then
    GPGKEY=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial
    rm -f /etc/yum.repos.d/centos{,-addons}.repo
    for variant in BaseOS AppStream CRB HighAvailability NFV RT ResilientStorage; do
        mkrepo "centos-master-$variant" "https://mirror.stream.centos.org/\$stream/$variant/\$basearch/os/"
        mkrepo "centos-master-$variant-source" "https://mirror.stream.centos.org/\$stream/$variant/source/tree/" 0
        mkrepo "centos-master-$variant-debuginfo" "https://mirror.stream.centos.org/\$stream/$variant/\$basearch/debug/tree/" 0
        echo
    done > /etc/yum.repos.d/centos-master.repo
elif [[ $os_id == fedora ]]; then
    GPGKEY=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
    rm -f /etc/yum.repos.d/fedora{.repo,-*}
    {
        mkrepo "fedora-dl-releases" "https://dl.fedoraproject.org/pub/fedora/linux/releases/\$releasever/Everything/\$basearch/os/"
        mkrepo "fedora-dl-releases-source" "https://dl.fedoraproject.org/pub/fedora/linux/releases/\$releasever/Everything/source/tree/" 0
        mkrepo "fedora-dl-releases-debuginfo" "https://dl.fedoraproject.org/pub/fedora/linux/releases/\$releasever/Everything/\$basearch/debug/tree/" 0
        # updates is missing the last path element (/os/ or /tree/)
        mkrepo "fedora-dl-updates" "https://dl.fedoraproject.org/pub/fedora/linux/updates/\$releasever/Everything/\$basearch/"
        mkrepo "fedora-dl-updates-source" "https://dl.fedoraproject.org/pub/fedora/linux/updates/\$releasever/Everything/source/" 0
        mkrepo "fedora-dl-updates-debuginfo" "https://dl.fedoraproject.org/pub/fedora/linux/updates/\$releasever/Everything/\$basearch/debug/" 0
        echo
    } > /etc/yum.repos.d/fedora-dl.repo
fi

# ------------------------------------------------------------------------------

# on RHEL, switch to gpgcheck=1 (because Testing Farm defaults to gpgcheck=0
# for historical reasons)
if grep -q '^name=rhel-BaseOS$' /etc/yum.repos.d/rhel.repo 2>/dev/null; then
    rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-*
    sed 's/^gpgcheck=0$/gpgcheck=1/' -i /etc/yum.repos.d/rhel.repo
fi

# ------------------------------------------------------------------------------

# remove useless legacy mountpoints (some have sticky bits)
umount -f /mnt/* || true
rmdir /mnt/*/*/* /mnt/*/* /mnt/* || true
sed -rn '/^[^ ]+ \/mnt/!p' -i /etc/fstab
# prevent /mnt/scratch* from being created on reboot
echo -n > /etc/tmpfiles.d/restraint.conf

# ------------------------------------------------------------------------------

# install SSH key
if [[ $RESERVE_SSH_PUBKEY ]]; then
    mkdir -p ~/.ssh
    chmod 0700 ~/.ssh
    echo "$RESERVE_SSH_PUBKEY" >> ~/.ssh/authorized_keys
    chmod 0600 ~/.ssh/authorized_keys
else
    echo "RESERVE_SSH_PUBKEY env var not defined" >&2
    exit 1
fi

# ------------------------------------------------------------------------------

exec sleep inf
exit 1  # fallback
