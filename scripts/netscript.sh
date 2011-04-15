#!/bin/bash
# Filename:      netscript.sh
# Purpose:       automatically deploy FAI server using Grml and its netscript bootoption
# Authors:       (c) Michael Prokop <mika@grml.org>
################################################################################

# Execute "the real script" with its standard output going to
# both stdout and netscript.sh.log, with its standard error going to
# both stderr and netscript.sh.errors, and with errorlevel passing.
#myname=$0
#rm -f "$myname".rc
#( (
#exec >&3
#trap "x=\$?; echo \$x >'$myname'.rc; exit \$x" EXIT

################################################################################
# the real script

# helper stuff {{{

# be careful, we want to be aware of any errors
# we don't cover yet...
set -e

HOST=$(hostname)

log() {
  printf "Info: $*\n"
}

error() {
  printf "Error: $*\n">&2
}
# }}}

# main execution functions {{{
get_fai_config() {
   . /etc/grml/autoconfig.functions
   CONFIG="$(getbootparam 'netscript' 2>/dev/null)"
   FAI_CONF="${CONFIG%%netscript.sh}fai.conf"
   if [ -n "$FAI_CONF" ] ; then
     cd /tmp
     wget -O fai.conf $FAI_CONF
   else
     error "Error retrieving FAI configuration. :("
     exit 1
   fi

   . fai.conf
}

software_install() {
  if [ -z "$FAI_MIRROR" ] ; then
    log "Configuration \$FAI_MIRROR unset, skipping sources.list step."
  else
    log "Adjusting /etc/apt/sources.list.d/fai.list"
    if ! grep -q "$FAI_MIRROR" /etc/apt/sources.list.d/fai.list &>/dev/null ; then
      echo "$FAI_MIRROR" >> /etc/apt/sources.list.d/fai.list
    fi
  fi

  if [ -z "$PACKAGES" ] ; then
    PACKAGES="fai-client fai-doc fai-server fai-setup-storage \
atftpd dnsmasq imvirt isc-dhcp-server nfs-kernel-server"
  fi

  # might not work immediately, so let's give it a chance to complete
  log "Update software package information."
  for i in {1..10}; do
    if aptitude update ; then
      break
    else
      log "Problem retrieving package information, will try again..."
      sleep 5
    fi
    if [[ "$i" -eq 10 ]] ; then
      error "Error retriving software package list, giving up."
      exit 1
    fi
  done

  log "Installing software"
  APT_LISTCHANGES_FRONTEND=none APT_LISTBUGS_FRONTEND=none \
    DEBIAN_FRONTEND=noninteractive apt-get -y --force-yes \
    --no-install-recommends install $PACKAGES
}

prechecks() {
  # this is WFM, but makes sure the script is executed under KVM only
  if [[ "$(imvirt)" == "KVM" ]] || grep 'model name' /proc/cpuinfo | grep -q 'QEMU' ; then
    log "Running inside KVM/QEMU, will continue..."
  else
    error "Not running inside KVM/QEMU as expected, will not continue."
    exit 1
  fi
}

dhcpd_conf() {
  # note:
  # dhcp3-server    == /etc/dhcp3/
  # isc-dhcp-server == /etc/dhcp/
  log "Adjusting dhcpd configuration"
  if ! grep -q '^# FAI deployment script' /etc/dhcp/dhcpd.conf ; then
    cat >> /etc/dhcp/dhcpd.conf << EOF
# FAI deployment script
subnet 192.168.10.0 netmask 255.255.255.0 {
  range 192.168.10.50 192.168.10.200;
  option routers 192.168.10.1;
  option domain-name-servers 192.168.10.1;
  next-server 192.168.10.1;
  filename "pxelinux.0";
}
EOF
  fi

  if [ -r /etc/default/isc-dhcp-server ] ; then
    sed -i 's/INTERFACES=.*/INTERFACES="eth1"/' /etc/default/isc-dhcp-server
  fi
}

tftpd_hpda_conf() {
  if grep -q '^# FAI deployment script' /etc/default/tftpd-hpa ; then
    return 0
  fi

  # newer tftpd-hpa
  if grep -q 'TFTP_DIRECTORY' /etc/default/tftpd-hpa ; then
    cat > /etc/default/tftpd-hpa << EOF
# FAI deployment script
TFTP_DIRECTORY='/srv/tftp/fai'
TFTP_ADDRESS="0.0.0.0:69"
TFTP_USERNAME="tftp"
RUN_DAEMON="yes"
TFTP_OPTIONS="--secure"
EOF

  else # older tftpd-hpa
    cat > /etc/default/tftpd-hpa << EOF
# FAI deployment script
RUN_DAEMON="yes"
OPTIONS="-l -s /srv/tftp/fai"
EOF
  fi
}

atftpd_conf() {
 if grep -q '^# FAI deployment script' /etc/default/atftpd ; then
   return 0
 fi

 cat > /etc/default/atftpd << EOF
# FAI deployment script
USE_INETD=false
OPTIONS="--daemon --no-multicast --bind-address 192.168.10.1 /srv/tftp/fai"
EOF
}

tftpd_conf() {
  log "Adjusting tftpd configuration"

  if [ -r /etc/default/tftpd-hpa ] ; then
    tftpd_hpda_conf
  elif [ -r /etc/default/atftpd ] ; then
    atftpd_conf
  else
    error "No supported (atftpd/tftpd-hpa) tftpd found."
    exit 1
  fi
}

network_conf() {
  log "Adjusting network configuration"
  if ! grep -q '^# FAI deployment script' /etc/network/interfaces ; then
  cat > /etc/network/interfaces << EOF
# FAI deployment script
iface lo inet loopback
auto lo

auto eth1
iface eth1 inet static
  address 192.168.10.1
  netmask 255.255.255.0
# gateway 192.168.10.1
EOF
  fi

  # required so dhclient doesn't listen on eth1 anymore
  ifdown eth1
  # be 100% sure :-/
  kill -9 $(pgrep -f dhclient.eth1)

  /etc/init.d/networking restart

  echo 1 > /proc/sys/net/ipv4/ip_forward
  iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
}

hosts_conf() {
  log "Adjusting /etc/hosts"
  if ! grep -q '^# FAI deployment script' /etc/hosts ; then
    cat >> /etc/hosts << EOF
# FAI deployment script
192.168.10.1  ${HOST}
EOF
  fi
}

fai_conf() {
  log "Adjusting FAI configuration"

  sed -i "s;FAI_DEBOOTSTRAP=.*;FAI_DEBOOTSTRAP=\"lenny http://${DEBIAN_MIRROR}/debian\";" \
      /etc/fai/make-fai-nfsroot.conf
  sed -i "s/cdn.debian.net/${DEBIAN_MIRROR}/" /etc/fai/apt/sources.list

  # make sure new FAI version is available inside nfsroot as well
  if ! grep -q '^# FAI deployment script' /etc/fai/apt/sources.list ; then
    cat >> /etc/fai/apt/sources.list << EOF
# FAI deployment script
$FAI_MIRROR
EOF
  fi

  if [ -z "${FAI_CONFIG_SRC:-}" ] ; then
    FAI_CONFIG_SRC="nfs://$HOST/srv/fai/config"
    ## use specific config space depending on FAI version, example:
    # FAI_VERSION=$(dpkg --list fai-server | awk '/^ii/ {print $3}')
    # if dpkg --compare-versions $FAI_VERSION gt 3.5 ; then
    #   FAI_CONFIG_SRC=svn://svn.debian.org/svn/fai/trunk/examples/simple/
    # else
    #   FAI_CONFIG_SRC=svn://svn.debian.org/svn/fai/branches/stable/3.4/examples/simple/
    # fi
  fi

  if grep -q '^FAI_CONFIG_SRC' /etc/fai/fai.conf ; then
    sed -i "s;^FAI_CONFIG_SRC=.*;FAI_CONFIG_SRC=\"$FAI_CONFIG_SRC\";" /etc/fai/fai.conf
  else
    cat >> /etc/fai/fai.conf << EOF
# FAI deployment script
FAI_CONFIG_SRC="$FAI_CONFIG_SRC"
EOF
  fi
}

nfs_setup() {
  # fai-setup rebuilds nfsroot each time, we want
  # to be able to skip that and just export /srv/* via nfs
  # if  we have a nfsroot already we want to reuse, see #600195
  if ! grep -q '^/srv' /etc/exports ; then
    cat >> /etc/exports << EOF
# FAI deployment script
/srv/fai/config 192.168.10.1/24(async,ro,no_subtree_check)
/srv/fai/nfsroot 192.168.10.1/24(async,ro,no_subtree_check,no_root_squash)
EOF
    /etc/init.d/nfs-kernel-server restart
  fi
}

disk_setup() {

  if [ -r /srv/fai_netscript_done ] ; then
    if grep -q 'fai_rebuild' /proc/cmdline ; then
      log "Rebuilding /srv on $DISK as requested via fai_rebuild bootoption."
      umount /srv
    else
      log "Disk $DISK present already on /srv, skipping disk setup."
      return 0
    fi
  fi

  # existing installation present? re-use it
  # just rm -rf /srv to force re-installation of FAI
  if mount /dev/${DISK}1 /srv ; then
    log "Existing partition found, trying to re-use."

    if ! [ -r /srv/fai_netscript_done ] ; then
      log "No /srv/fai_netscript_done found, will continue to formating disk."
      umount /srv
    else

      if grep -q 'fai_rebuild' /proc/cmdline ; then
        log "Rebuilding /srv on $DISK as requested via fai_rebuild bootoption."
	umount /srv
      else
        log "/srv/fai_netscript_done present on $DISK - skipping disk setup."
        return 0
      fi

    fi
  fi

  log "Formating disk $DISK:"
  # this is another WFM, but makes sure I format just disks inside QEMU :)
  if ! grep -q 'QEMU HARDDISK' /sys/block/${DISK}/device/model ; then
    error "Disk $DISK does not look as expected (QEMU HARDDISK)."
    exit 1
  else
    export LOGDIR=/tmp/setup-storage
    [ -d "$LOGDIR" ] || mkdir -p $LOGDIR
    export disklist=$(/usr/lib/fai/disk-info | sort)

    cat << EOT | setup-storage -X -f -
disk_config $DISK
primary - 100% ext3 rw
EOT
  fi

  mv /srv /srv.old
  mkdir /srv
  mount /dev/${DISK}1 /srv
  mv /srv.old/* /srv/ || true
  rmdir /srv.old
  touch /srv/fai_netscript_done
}

fai_setup() {
  # if testing FAI 4.x do not use existing base.tgz
#  FAI_VERSION=$(dpkg --list fai-server | awk '/^ii/ {print $3}')
#  if dpkg --compare-versions $FAI_VERSION gt 3.5 ; then
#    echo "Not installing base.tgz, as version of FAI greater than 3.5."
#  else
#    # download base.tgz to save time...
#    # TODO: support different archs, detect etch/lenny/....
#    if wget 10.0.2.2:8000/base.tgz ; then
#      [ -d /srv/fai/config/basefiles/ ] || mkdir /srv/fai/config/basefiles/
#      mv base.tgz /srv/fai/config/basefiles/FAIBASE.tgz
#    fi
#  fi

  if ! [ -d /srv/fai/nfsroot/live/filesystem.dir ] ; then
    log "Executing fai-setup"
    if [ -r /srv/fai/config/basefiles/FAIBASE.tgz ] ; then
      fai-setup -v -B /srv/fai/config/basefiles/FAIBASE.tgz | tee /tmp/fai-setup.log
    else
      fai-setup -v | tee /tmp/fai-setup.log
    fi
  fi

  # as fallback
  [ -d /srv/fai/config/ ] || mkdir -p /srv/fai/config/
  cp -a /usr/share/doc/fai-doc/examples/simple/* /srv/fai/config/

  log "Executing fai-chboot for default host"
  fai-chboot -IFv default
}

adjust_services() {
  log "Restarting services"
  # brrrrr, but works...
  if [ -x /etc/init.d/portmap ] ; then
    /etc/init.d/portmap restart
  fi

  if [ -x /etc/init.d/nfs-common ] ; then
    /etc/init.d/nfs-common restart
  fi

  if [ -x /etc/init.d/rpcbind ] ; then
    /etc/init.d/rpcbind restart
  fi

  if [ -x /etc/init.d/nfs-kernel-server ] ; then
    /etc/init.d/nfs-kernel-server restart || true
  fi

  # otherwise "nfsd mountd" might not be running :-/
  if ! rpcinfo -p localhost >/dev/null ; then
    if [ -x /etc/init.d/portmap ] ; then
      /etc/init.d/portmap restart
    fi
    if [ -x /etc/init.d/rpcbind ] ; then
      /etc/init.d/rpcbind restart
    fi
  fi

  if ! showmount -e localhost | grep -q /srv/fai ; then
    /etc/init.d/nfs-kernel-server restart || true
  fi

  if [ -x /etc/init.d/dnsmasq ] ; then
    /etc/init.d/dnsmasq restart
  fi

  # we want to use tftpd-hpa/atftpd standalone,
  # to avoid conflicts because of already-running
  # services lets stop the inetutils-inetd stuff instead
  if [ -x /etc/init.d/inetutils-inetd ] ; then
    /etc/init.d/inetutils-inetd stop || true
  fi

  if [ -x /etc/init.d/tftpd-hpa ] ; then
    /etc/init.d/tftpd-hpa restart
  else
    /etc/init.d/atftpd restart
  fi

  if [ -x /etc/init.d/isc-dhcp-server ] ; then
    /etc/init.d/isc-dhcp-server restart
  else
    /etc/init.d/dhcp3-server restart
  fi
}

# main execution itself {{{

main() {
  get_fai_config
  software_install
  prechecks
  dhcpd_conf
  tftpd_conf
  network_conf
  hosts_conf
  fai_conf
  disk_setup
  nfs_setup
  fai_setup
  adjust_services
}

# if executed via netscript bootoption, a simple and stupid check
# to execute only under according environment
if [[ "$SHLVL" == "2" ]] || [ -n "${NETSCRIPT:-}" ] ; then
  main
  rc=$?
  echo "status report from $(date)
rc=$rc" | telnet 10.0.2.2 8888 || true
fi
# }}}

#) 2>&1 | tee "$myname".errors >&2) 3>&1 | tee "$myname".log
#rc=$(cat "$myname".rc 2>/dev/null)
#rm -f "$myname".rc
#exit $rc

## END OF FILE #################################################################
