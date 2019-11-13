import subprocess


class Icingainstance:
    def __init__(self):
        try:
            versionoutput = subprocess.check_output(["icinga2", "--version"]).splitlines()
            for line in versionoutput:
                if "Icinga 2 network monitoring daemon" in line:
                    self.version = str(line.split(':')[1].split('-')[0])
        except:
            self.version = "Not installed"


def get_icinga2_info():
    return Icingainstance()
