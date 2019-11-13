# Icinga Diagnostics
# Collect basic data about your Icinga 2 installation
# maintainer: Thomas Widhalm <thomas.widhalm@icinga.com>
# Original source: https://github.com/icinga/icinga2-diagnostics

# ToDo:
# socket.gethostname just get's the short name. getfqdn return localhost

import getpass
import logging
import platform
import sys
from datetime import datetime

from diagnostics.Icinga2 import get_icinga2_info
from diagnostics.Oshost import get_host

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

# print header

logger.info("""### Icinga Diagnostics ###
# Version: {} 
# Run on {} at {}""".format(version, platform.node(), datetime.now().strftime("%Y-%m-%d %H:%M:%S")))

# check whether we are running as root or not

if str(getpass.getuser()) != "root":
    logger.info("""
    Not running as root. Not all checks might be successful
    """)
    runasroot = False

host_info = get_host()

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

icinga_info = get_icinga2_info()

print("Icinga 2: " + icinga_info.version)
