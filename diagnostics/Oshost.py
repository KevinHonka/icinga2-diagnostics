import multiprocessing
import os
import platform
import subprocess


class Oshost:

    def __init__(self):
        self.os = None
        self.vm = None
        self.virtual = None
        self.python_version = None
        self.cpu_cores = None
        self.memory = None

        self.get_os_info()

    def get_os_info(self):

        self.python_version = platform.python_version()
        self.cpu_cores = multiprocessing.cpu_count()
        self.memory = (os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES')) // (1024. ** 3)

        self.os = platform.platform()
        try:
            self.virtual = str(subprocess.check_output(["virt-what"]))
        except subprocess.CalledProcessError as error:
            self.virtual = "Not determinable. Not running as root?"


def get_host():
    return Oshost()
