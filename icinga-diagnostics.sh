#!/bin/sh
# Icinga Diagnostics
# Collect basic data about your Icinga 2 installation
# maintainer: Thomas Widhalm <thomas.widhalm@icinga.com>
# Original source: https://github.com/widhalmt/icinga2-diagnostics

VERSION=0.1.0

echo "### Icinga 2 Diagnostics ###"
echo "# Version: ${VERSION}"
echo "# Run on $(hostname) at $(date)"
echo ""

### VARIABLES ###

## Static variables ##

OPTSTR="fhtzg"

TIMESTAMP=$(date +%Y%m%d)
UNAME_S=$(uname -s)

# The GnuPG key used for signing packages in the Icinga repository
ICINGAKEY="c6e319c334410682"

ANOMALIESFOUND=0
SYNCEDZONES=0
PHPINITIMEZONEMISSING=false

## Computed variables ##

if [ "$(id -u)" != "0" ]; then
  echo "Not running as root. Not all checks might be successful"
  RUNASROOT=false
else
  echo "Running as root"
  RUNASROOT=true
fi

if [ $(which systemctl 2>/dev/null) ]
then
  SYSTEMD=true
fi

if [ -f "/etc/redhat-release" ]
then
  QUERYPACKAGE="rpm -q"
  OS="REDHAT"
  OSVERSION="$(cat /etc/redhat-release)"
elif [ -f "/etc/debian_version" ]
then
  QUERYPACKAGE="dpkg -l"
  OS="$(grep ^NAME /etc/os-release | cut -d\" -f2)"
  OSVERSION="${OS} $(cat /etc/debian_version)"
elif [ "${UNAME_S}" = "FreeBSD" ]
then
  QUERYPACKAGE="pkg info"
  OS="${UNAME_S}"
  PREFIX="/usr/local"
  uname -srm 
elif [ -f "/etc/os-release" ]
then
  QUERYPACKAGE="rpm -q"
  OS="SuSE"
  OSVERSION="$(cat /etc/os-release | grep -e '^NAME' -e '^VERSION\b'| cut -d\" -f2)"
else
  # could not use the following check because this package is optional on some distributions
  lsb_release -irs
fi

### Functions ###

show_help() {
  echo "

  Usage:
  -f add full Icinga 2 configuration to output (use with -t)
  -h show this help
  -t create a tarball instead of just printing the output
  -z list all zones in standard output (ignored in "full" mode)
  -g provide gdb output for debugging
  "
  exit 0
}

check_service() {
  if [ "${SYSTEMD}" = "true" ]
  then
    systemctl show $1.service -p ActiveState | cut -d= -f2
  else
    service $1 status > /dev/null && echo "active" || echo "inactive"
  fi
}

doc_icinga2() {

  # Check if debuglog is active
  if [ "$(icinga2 feature list | egrep '^Enabled.*debuglog' | wc -l)" -gt 0 ]
  then
    #echo "Debuglog is enabled"
    IC2_DEBUGLOG=true
  else
    echo "Debuglog is disabled. Not all checks might succeed"
    IC2_DEBUGLOG=false
    echo ""
  fi


  # query all installed packages with "icinga" in their name
  # check every package whether it was signed with the GnuPG key of the icinga team
  echo "## Packages: ##"
  echo ""
  case "${OS}" in
    REDHAT|SuSE)
      if [ ! ${FULL} ]
      then
        echo -n "Icinga 2  "
        rpm -qi icinga2 | grep Version
      fi
      for i in $(rpm -qa | grep icinga)
      do
        if [ ${FULL} ]
        then
          rpm -qi $i | grep ^Name | cut -d: -f2
          rpm -qi $i | grep Version
        fi
        if [ ! "$(rpm -qi $i | grep ^Signature | cut -d, -f3 | awk '{print $3}')" = "${ICINGAKEY}" ]
        then
          NON_ICINGA_PACKAGES="${NON_ICINGA_PACKAGES} $i"
        fi
      done
      ;;
    FreeBSD) ${QUERYPACKAGE} -x icinga ;;
    *) echo "Can not query packages on ${OS}" ;;
  esac
  # if not in full mode there is no output. So at least inform the user about what happened.
  if [ ! ${FULL} ]
  then
    echo ""
    echo "Done checking packages. See Anomaly section if something odd was found."
  fi

  # rpm -q --queryformat '%|DSAHEADER?{%{DSAHEADER:pgpsig}}:{%|RSAHEADER?{%{RSAHEADER:pgpsig}}:{%|SIGGPG?{%{SIGGPG:pgpsig}}:{%|SIGPGP?{%{SIGPGP:pgpsig}}:{(none)}|}|}|}|\n\' icinga2

  echo ""
  echo "Features:"
  icinga2 feature list

  if [ ${ZONES} ]
  then
    # change the IFS variable to have whitespaces not split up items in a `for i in` loop.
    # this is to be used because some zone-names might contain whitespaces
    SAVEIFS=${IFS}
    IFS=$(printf "\n\b")
    echo ""
    echo "Zones and Endpoints:"
    for i in $(icinga2 object list --type zone | grep ^Object | cut -d\' -f2)
    do
      echo $i
      icinga2 object list --type Zone --name $i | grep -e 'endpoints =' -e 'parent =' -e 'global =' | grep -v -e '= null' -e '= false' -e '= ""'
    done
    IFS=${SAVEIFS}
  fi
  echo ""

  while read -d';' -r line
  do
    ZONENAME=$(echo ${line} | cut -d\' -f2)
    ZONEPATH=$(echo ${line} | cut -d\' -f6)
    if [ "$( echo ${ZONEPATH} | grep 'zones.d' )" ]
    then
      if [ -d "/etc/icinga2/zones.d/${ZONENAME}" > /dev/null 2>&1 ]
      then
        echo "Zone ${ZONENAME} might be configured wrong. See anomalies section for details"
        SYNCEDZONES=$((SYNCEDZONES+1))
      fi
      for i in $(ls /var/lib/icinga2/api/packages/); do
        if [ -d "/var/lib/icinga2/api/packages/$i/$(cat /var/lib/icinga2/api/packages/$i/active-stage)/zones.d/${ZONENAME}" > /dev/null 2>&1 ]
        then
          echo "Zone ${ZONENAME} in package ${i} might be configured wrong. See anomalies section for details"
          SYNCEDZONES=$((SYNCEDZONES+1))
        fi
      done
    fi
  done <<< $(icinga2 object list | egrep -A1 '^Object.* of type .Zone' | tr -d '\n' | sed 's/--/;/g')

  # calculating how many non-global zones have more than 2 endpoints configured
  # result is used in anomaly-detection
  BIGZONES=$(icinga2 object list --type zone  | grep endpoints  | grep -n -o '"' | sort | uniq -c | egrep -v ^[[:space:]]*[24] | wc -l)

  # check if hostname is endpointname
  # it's perfectly ok to use different ones but since it's best practice to have them identical
  # we should check that

  if [ "$(icinga2 variable get NodeName)" = "$(hostname -f)" ]
  then
    ENDPOINTISNODENAME=true
  else
    ENDPOINTISNODENAME=false
  fi

  echo ""
  # count how often every check interval is used. This helps with getting an overview and finding misconfigurations
  # * are there lots of different intervals? -> Users might get confused
  # * very high or very low intervals -> could mean messed up units (e.g.: s instead of m)
  # * many different intervals? -> could lead to problems with graphs
  echo "Check intervals:"
  icinga2 object list --type Host | grep check_interval | sort | uniq -c | sort -rn | sed 's/$/, Host/'
  icinga2 object list --type Service | grep check_interval | sort | uniq -c | sort -rn | sed 's/$/, Service/'
  if [ "${IC2_DEBUGLOG}" = true ]
  then
    echo ""
    echo "Used commands (numbers are relative to each other, not showing configured objects):"
    grep 'Running command'  /var/log/icinga2/debug.log | cut -d\' -f2 | sort | uniq -c | sort -rn
  fi

  # add a config check. Not only to see if something is wrong with the configuration but to get the summary of all configured objects as well
  echo ""
  icinga2 daemon -C

  if [ ${GDB} ]
  then
    if [ $(which gdb) > /dev/null ]
    then
      echo ""
      echo "## gdb Output ##"
      echo ""
      gdb -p $(pidof icinga2 | cut -d" " -f1) -x ./icinga-gdb -batch
      echo ""
    else
      echo "GDB mode requested but gdb not found"
    fi
  fi

}

doc_icingaweb2() {

  echo ""
  echo "Packages:"
  ${QUERYPACKAGE} icingaweb2
  if [ "${UNAME_S}" = "FreeBSD" ]; then
    ${QUERYPACKAGE} -x php
    ${QUERYPACKAGE} -x apache
    ${QUERYPACKAGE} -x nginx
    ${QUERYPACKAGE} -g '*sql*-server'
  else
    ${QUERYPACKAGE} php
  fi
  if [ "${OS}" = "REDHAT" ]
  then
    ${QUERYPACKAGE} httpd
  else
    echo "Can not query webserver package on ${OS}"
  fi

  echo ""
  echo "Icinga Web 2 Modules:"
  # Add options for modules in other directories
  icingacli module list
  for i in $(icingacli module list | grep -v ^MODULE | awk '{print $1}')
  do
    if [ -d ${PREFIX}/usr/share/icingaweb2/modules/$i/.git ]
    then
      echo "$i via git - $(cd ${PREFIX}/usr/share/icingaweb2/modules/$i && git log -1 --format=\"%H\")"
    else
      echo "$i via release archive/package"
    fi
  done

  echo ""
  echo "Icinga Web 2 commandtransport configuration:"
  cat ${PREFIX}/etc/icingaweb2/modules/monitoring/commandtransports.ini | sed '/password/s/"[^"]*"/MASKED/' 

  # Director diagnostics

  echo ""

  if [ $(icingacli module list | grep ^director | wc -l) -gt 0 ]
  then
    # determine director version from icingacli once. We might need it again later
    DIRECTOR_VERSION="$(icingacli module list | grep director | awk '{print $2}')"
    if [ "${DIRECTOR_VERSION}" = "master" ]
    then
      # no release was downloaded
      DIRECTOR_NO_RELEASE=true
      if [ -d "${PREFIX}/usr/share/icingaweb2/modules/director/.git" ]
      then
        # .git directory normally means this is a git clone
        # if this is just a local git directory we'll see that in the git log
        echo "Director is a git clone with the following last commit"
        echo ""
        IDPWD=$(pwd)
        cd ${PREFIX}/usr/share/icingaweb2/modules/director/ > /dev/null && (git log -n1)
        cd "${IDPWD}"
      else
        echo "Director is a downloaded git master with no known way of determining the version"
      fi
    else
      echo "Director is release ${DIRECTOR_VERSION}"
      if [ -d "${PREFIX}/usr/share/icingaweb2/modules/director/.git" ]
      then
        echo "Director was installed as a git clone"
        # trigger anomaly detection because it's hard to determine if a git clone is really a
        # release or just by accident the latest release
        DIRECTOR_NO_RELEASE=true
      else
        echo "Director was installed by downloading a release archive"
      fi
    fi 
  else
    echo "Icinga Director is not installed or is deactivated"
  fi

  # check for timezone settings in php.ini #

  PHPINICOUNT=0
  for i in $(find / -name php.ini 2>/dev/null)
  do
    PHPINICOUNT=$((PHPINICOUNT+1))
    if [ -z "$(grep ^date.timezone $i)" ]
    then
      PHPINITIMEZONEMISSING=true
    fi
  done

}

doc_firewall() {
  echo -n "Firewall: "

  if [ "$1" = "f" ]
  then  
    if [ "${RUNASROOT}" = "true" ]
    then
      case "${UNAME_S}" in
        Linux) iptables -nvL ;;
        FreeBSD)
          pfctl -s rules 2>/dev/null
          ipfw show 2>/dev/null
          ;;
        *) ;;
      esac
    else
      echo "# Can not read firewall configuration without root permissions #"
    fi
  else
    if [ "${SYSTEMD}" = "true" ]
    then
      check_service firewalld
    else
      check_service iptables
    fi
  fi 
}

doc_os() {

  echo ""
  echo "## OS ##"
  echo ""
  echo -n "OS Version: "

  echo ${OSVERSION}

  echo -n "Hypervisor: "

  case "${UNAME_S}" in
    Linux)
      HYPERVISOR=$(hostnamectl 2>/dev/null | grep "Virtualization:" | awk '{print $2}')
# If NULL
if [ -z "${HYPERVISOR}" ]
then
        # Try an another way
        HYPERVISOR=$(virt-what 2>/dev/null | awk '{print $1}')
        # If NULL again
        if [ -z "${HYPERVISOR}" ]
        then
		VIRTUAL=false
        else
		VIRTUAL=true
        fi
else
	VIRTUAL=true
fi

      ;;
    FreeBSD)
      VIRT="$(sysctl -n kern.vm_guest)" 
      VIRTUAL=true
      case "${VIRT}" in 
        none)          VIRTUAL=false ;;
        generic|bhyve) HYPERVISOR=byhve ;;
        xen)           HYPERVISOR=Xen ;;
        hv)            HYPERVISOR=Hyper-V ;;
        vmware)        HYPERVISOR=VMware ;;
        kvm)           HYPERVISOR=KVM ;;
        *) ;; #XXX
      esac
      ;;
    *) ;; # XXX
  esac

  if [ "${VIRTUAL}" = "false" -o -z "${VIRTUAL}" ]
  then
    if [ "${RUNASROOT}" = "true" ]
    then
      echo "Running on Hardware or unknown Hypervisor"
    else
      echo "Insufficient permissions to check Hypervisor"
    fi
  else
    echo "Running virtually on a ${HYPERVISOR} hypervisor"
  fi

  #dmidecode | grep -i vmware
  #lspci | grep -i vmware
  #grep -q ^flags.*\ hypervisor\ /proc/cpuinfo && echo "This machine is a VM"

  case "${UNAME_S}" in
    Linux)
      echo -n "CPU cores: "
      cat /proc/cpuinfo | grep ^processor | wc -l
      echo -n "RAM: "
      if [ "${OS}" = "SuSE" ]
      then
        free - g | grep Mem | awk '{print $2 / 1024"MB"}'
      else
        free -h | grep ^Mem | awk '{print $2}'
      fi
      ;;
    FreeBSD)
      echo -n "CPU cores: "
      sysctl -n hw.ncpu
      echo -n "RAM: "
      echo $(expr $(sysctl -n hw.physmem) / 1024 / 1024) MB
      ;;
    *) ;;
  esac

  echo ""
  echo "### Top output ###"
  echo ""
  top -b -n 1 | head -n5
  echo ""

  ZOMBIES="$(ps axo stat=,command= | grep ^Z | sed 's/^S[[:blank:]]//g' | sort | uniq -c | sort -n)"
  if [ ! -z "${ZOMBIES}" ]
  then
    echo "### Zombies ###"
    echo ""
    echo "${ZOMBIES}"
    echo ""
  fi


  if [ "${OS}" = "REDHAT" ]
  then
    echo -n "SELinux: "
    getenforce
  fi

  ## troubleshooting SELinux for Icinga 2
  #semodule -l | grep -e icinga2 -e nagios -e apache
  #ps -eZ | grep icinga2
  #semanage port -l | grep icinga2
  #getsebool -a | grep icinga2
  #audit2allow -li /var/log/audit/audit.log

  doc_firewall
  echo -n "OpenSSL Version $(which openssl): "
  openssl version

}

create_tarball() {
  OUTPUTDIR=$(mktemp -dt ic_diag.XXXXX)
  # run this diagnostics script again and print it's output into the tarball
  if [ "${FULL}" = true ]
  then
    $0 -f > ${OUTPUTDIR}/icinga_diagnostics
  else
    $0 > ${OUTPUTDIR}/icinga_diagnostics
  fi
  # copy Icinga 2 configuration into tarball
  cp -a /etc/icinga2 ${OUTPUTDIR}/
  # copy Icinga Web 2 configuration into tarball
  cp -a /etc/icingaweb2 ${OUTPUTDIR}/
  # copy most recent logs
  cp /var/log/icinga2/icinga2.log ${OUTPUTDIR}/
  cp /var/log/icinga2/error.log ${OUTPUTDIR}/
  cp -r /var/log/icinga2/crash ${OUTPUTDIR}/
  top -b -n1 > ${OUTPUTDIR}/top
  if [ -f /var/log/icinga2/debug.log ]
  then
    cp /var/log/icinga2/debug.log ${OUTPUTDIR}/
  fi
  icinga2 --version > ${OUTPUTDIR}/icinga2_version
  # create tarball of all collected data
  if [ $(which bzip2 2>/dev/null) ]
  then
    cd ${OUTPUTDIR} && tar -cjf /tmp/icinga-diagnostics_$(hostname)_${TIMESTAMP}.tar.bz2 * 2>/dev/null
    chmod 0600 /tmp/icinga-diagnostics_$(hostname)_${TIMESTAMP}.tar.bz2
    if [ -s /tmp/icinga-diagnostics_$(hostname)_${TIMESTAMP}.tar.bz2 ]
    then
      echo "Your tarball is ready at: /tmp/icinga-diagnostics_$(hostname)_${TIMESTAMP}.tar.bz2"
    else
      echo "Something went wrong with creating the tarball. Size of file is zero."
    fi
  else
    cd ${OUTPUTDIR} && tar -czf /tmp/icinga-diagnostics_$(hostname)_${TIMESTAMP}.tar.gz * 2>/dev/null
    chmod 0600 /tmp/icinga-diagnostics_$(hostname)_${TIMESTAMP}.tar.gz
    if [ -s /tmp/icinga-diagnostics_$(hostname)_${TIMESTAMP}.tar.gz ]
    then
      echo "Your tarball is ready at: /tmp/icinga-diagnostics_$(hostname)_${TIMESTAMP}.tar.gz"
    else
      echo "Something went wrong with creating the tarball. Size of file is zero."
    fi
  fi
  exit 0
}

### Main ###


while getopts ${OPTSTR} SWITCHVAR
do
  case ${SWITCHVAR} in
    f) FULL=true;;
    h) show_help;;
    t) create_tarball;;
    z) ZONES=true;;
    g) GDB=true;;
  esac
done

# seems like not all `test` implementations understand `-o`
# therefore set all relevant booleans in full mode
if [ ${FULL} ]
then
  ZONES=true
  GDB=true
fi

doc_os

echo ""
echo "# Icinga 2 #"
echo ""
${QUERYPACKAGE} omd > /dev/null
OMD=$?
${QUERYPACKAGE} icinga2 > /dev/null
if [ $? -eq 0 -o $OMD -eq 0 ]
then
  doc_icinga2
else
  echo "Icinga 2 is not installed"
fi

echo ""
echo "# Icinga Web 2 #"
echo ""
${QUERYPACKAGE} icingaweb2 > /dev/null
if [ $? -eq 0 ]
then
  doc_icingaweb2
else
  echo "Icinga Web 2 is not installed"
fi

echo ""
echo "# Anomalies found #"
echo ""

if [ ${DIRECTOR_NO_RELEASE} ]
then
  echo "* Director is installed but no release archive was used for installation. (Please note that it still could the code of a release)"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi

if [ ! -z "${NON_ICINGA_PACKAGES}" ]
then
  echo "* The following packages were not signed with the Icinga GnuPG key: ${NON_ICINGA_PACKAGES}"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi

if [ ! -z "${ZOMBIES}" ]
then
  echo "* Zombie processes found. See output for details"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi

if [ $[${BIGZONES}+0] -gt 0 ]
then
  echo "* ${BIGZONES} non-global zones have more than 2 endpoints configured"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi

if [ "x${ENDPOINTISNODENAME}" = "xfalse" ]
then
  echo "* Name of Endpoint object differs from hostname"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi

if [ $[${PHPINICOUNT}+0] -gt 1 ]
then
  echo "* More than one php.ini file found"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi

if [ ${PHPINITIMEZONEMISSING} ]
then
  echo "* At least one php.ini file has no valid timezone setting"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi
if [ $(which ntpstat 2>/dev/null) ]
then
  ntpstat >/dev/null 2>&1
  if [ $? -gt 0 ]
  then
    echo "* NTP is not synchronized"
    ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
  fi
else
  echo "* ntpstat is not installed - NTP status uncheckable"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi

if [ ${SYNCEDZONES} -gt 0 ]
then
  echo "* Zone objects of non-command_endpoints being synced: ${SYNCEDZONES}. Please refer to https://github.com/Icinga/icinga2/issues/7530"
  ANOMALIESFOUND=$((${ANOMALIESFOUND}+1))
fi

echo ""
echo "Total count of detected anomalies: ${ANOMALIESFOUND}"
