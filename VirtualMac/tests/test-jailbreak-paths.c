#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/un.h>
#include "../vz/host/VZPaths.h"

int main(void)
{
    assert(strcmp(VZRuntimePath("payload"), "/var/root/VirtualMac/payload") == 0);
    assert(strcmp(VZStatePath("Settings.plist"), "/var/mobile/Media/VirtualMac/Settings.plist") == 0);
    assert(strcmp(VZTemporaryPath("vmmhook.log"), "/tmp/vmmhook.log") == 0);
    assert(strcmp(VZRestorePath("installationhook.log"), "/tmp/installationhook.log") == 0);
    assert(strcmp(VZSocketPath("vz-usb-restore.sock"), "/tmp/vz-usb-restore.sock") == 0);
    assert(strcmp(VZInstallationsRoot, "/var/mobile/Media/VirtualMac/Installations") == 0);
    assert(strcmp(VZLibraryRoot, "/var/mobile/Media/VirtualMac") == 0);
    assert(strcmp(VZRestoreImagesRoot, "/var/mobile/Media/VirtualMac/Restore Images") == 0);
    assert(strcmp(VZDHCPLeasesPath, "/var/db/dhcpd_leases") == 0);
    assert(strcmp(VZUSBMuxSocket, "/var/run/usbmuxd") == 0);
    assert(strcmp(VZBootstrapArgument("/var/mobile/Media/VirtualMac/test"),
                  "/var/mobile/Media/VirtualMac/test") == 0);
    assert(VZLogMode == 0666 && VZSocketMode == 0666);
    puts("Standard jailbreak paths and permissions are unchanged");
    return 0;
}
