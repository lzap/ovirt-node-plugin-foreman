#!/bin/bash
# vim: sw=2:ts=2:et
set -x
PLUGIN=ovirt-node-plugin-foreman
export debug=${1:-debug}
export proxy_repo=${2:-http://yum.theforeman.org/nightly/el6/x86_64/}
export repoowner=${3:-theforeman}
export branch=${4:-master}
export ovirt_node_tools_gittag=${5:-master}
export WITH_GIT_BRANCH=${6:-master}

# enable EPEL
if [[ -f /etc/redhat-release ]]; then
  _PKG=$(rpm -qa '(redhat|sl|centos|oraclelinux)-release(|-server|-workstation|-client|-computenode)')
  OS_VERSION=$(rpm -q --queryformat '%{VERSION}' $_PKG | grep -o '^[0-9]*')
  if [[ OS_VERSION = "7" ]]; then
    EPEL_REL="7-0.2"
    yum -y install http://dl.fedoraproject.org/pub/epel/beta/7/x86_64/epel-release-$EPEL_REL.noarch.rpm
  elif [[ OS_VERSION = "6" ]]; then
    EPEL_REL="6-8"
    rpm -Uvh http://dl.fedoraproject.org/pub/epel/6/x86_64/epel-release-$EPEL_REL.noarch.rpm
  else
    echo "Unknown RHEL version"
  fi
fi

# give the VM some time to finish booting and network configuration
while ! ping -c1 -w5 8.8.8.8 &>/dev/null; do true; done
yum -y install livecd-tools appliance-tools-minimizer fedora-packager \
  python-devel rpm-build createrepo selinux-policy-doc checkpolicy \
  selinux-policy-devel autoconf automake python-mock python-lockfile \
  python-nose git-review qemu-kvm hardlink git wget

# build plugin
pushd /root
SELINUXMODE=$(getenforce)
setenforce 1
export OVIRT_NODE_BASE=$PWD
export OVIRT_CACHE_DIR=~/ovirt-cache
export OVIRT_LOCAL_REPO=file://${OVIRT_CACHE_DIR}/ovirt
export REPO="$proxy_repo"
mkdir -p $OVIRT_CACHE_DIR
[ -d $PLUGIN ] || git clone --depth 1 https://github.com/$repoowner/$PLUGIN.git -b $branch
pushd $PLUGIN
git pull
if [[ "$debug" == "debug" ]]; then
  ./autogen.sh --enable-debug && make rpms publish
else
  ./autogen.sh && make rpms publish
fi
popd

# build iso
rm -f *.iso
wget -O /usr/bin/image-minimizer -c -N \
  https://git.fedorahosted.org/cgit/lorax.git/plain/src/bin/image-minimizer
chmod +x /usr/bin/image-minimizer
mkdir node-ws 2>/dev/null
pushd node-ws
[ -d ovirt-node-dev-utils ] || \
  git clone https://github.com/fabiand/ovirt-node-dev-utils.git dev-utils
  pushd dev-utils
  git checkout -b $ovirt_node_tools_gittag tags/$ovirt_node_tools_gittag
  popd
pushd dev-utils
[ -d ovirt-node ] || make install-build-requirements clone-repos git-update WITH_GIT_BRANCH=$WITH_GIT_BRANCH
grep $PLUGIN ovirt-node/recipe/common-pkgs.ks || \
  echo $PLUGIN >> ovirt-node/recipe/common-pkgs.ks
if [[ "$debug" == "debug" ]]; then
  sed -i 's/.*passwd -l root/#passwd -l root/g' ovirt-node/recipe/common-post.ks
else
  sed -i 's/.*passwd -l root/passwd -l root/g' ovirt-node/recipe/common-post.ks
fi
make iso | tee ../../make_iso.log
popd
popd
mv node-ws/dev-utils/ovirt-node-iso/*iso .
cp node-ws/dev-utils/ovirt-node-iso/ovirt-node-iso.ks .
cat ovirt-node-base-iso.ks
rm -rf tftpboot/ foreman.iso
ISO=$(ls *iso | head -n1)
ln -fs $ISO foreman.iso
livecd-iso-to-pxeboot foreman.iso
mv -f tftpboot/vmlinuz0 $ISO-vmlinuz
mv -f tftpboot/initrd0.img $ISO-img
ls *iso -la
popd
setenforce $SELINUXMODE
