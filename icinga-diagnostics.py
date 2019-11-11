# Icinga Diagnostics
# Collect basic data about your Icinga 2 installation
# maintainer: Thomas Widhalm <thomas.widhalm@icinga.com>
# Original source: https://github.com/icinga/icinga2-diagnostics

# ToDo:
# socket.gethostname just get's the short name. getfqdn return localhost

import getpass
import logging
import multiprocessing
import os
import platform
import subprocess
import sys
from datetime import datetime

try:
    from types import SimpleNamespace as Namespace
except ModuleNotFoundError:
    from argparse import Namespace

version = "0.2.0"
timestamp = datetime.now()

logger = logging.getLogger("Icinga2 Diagnostics")
streamhandler = logging.StreamHandler(sys.stdout)
streamhandler.format('%(message)s')
logger.addHandler(streamhandler)
logger.setLevel(logging.INFO)


def get_host_info():
    operatingsystem = platform.platform()
    pythonversion = platform.python_version()
    cpucores = multiprocessing.cpu_count()
    memory = (os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')) // (1024. ** 3)

    return Namespace(os=operatingsystem, pythonversion=pythonversion, cpucores=cpucores, memory=memory)


def get_icinga_info():
    try:
        versionoutput = subprocess.check_output(["icinga2", "--version"]).splitlines()
        for line in versionoutput:
            if "Icinga 2 network monitoring daemon" in line:
                icinga_version = str(line.split(':')[1].split('-')[0])
    except:
        icinga_version = "Not installed"

    return Namespace(version=icinga_version)


# print header

logging.info("""### Icinga Diagnostics ###
# Version: {} 
# Run on {} at {}""".format(version, platform.node(), datetime.now().strftime("%Y-%m-%d %H:%M:%S")))

# check whether we are running as root or not

if str(getpass.getuser()) != "root":
    logger.info("""
    Not running as root. Not all checks might be successful
    """)
    runasroot = False

host_info = get_host_info()

logger.info("""### OS ###
        """)

logger.info("OS: {}".format(host_info.operatingsystem))
# print("Virtualisation: " + icingahost.virt)
logger.info("Python: {}".format(host_info.pythonversion))
logger.info("CPU cores: {}".format(host_info.cpucores))
logger.info("RAM: {} Gi".format(host_info.memory))

print("""
### Icinga 2 ###
""")

icinga_info = get_icinga_info()

print("Icinga 2: " + icinga_info.version)
