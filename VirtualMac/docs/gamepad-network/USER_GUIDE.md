# iPad Gamepad Relay User Guide

This feature forwards one Bluetooth or USB controller connected to the iPad
into the macOS guest as a generic gamepad. Virtio Socket is used by default, so
the iPad and guest do not need IP connectivity.

## Requirements

- Install a Virtual Mac package that contains the gamepad relay.
- Pair the controller in iPadOS Bluetooth settings or connect it through USB.
- Enable Guest Tools for the macOS guest.
- The current packaged guest receiver is ad-hoc signed. On the tested macOS 14
  and macOS 15 guests, it requires SIP to be disabled and the
  `amfi_get_out_of_my_way=1` boot argument.

## Configure the macOS guest

1. Shut down the guest and enter macOS Recovery.
2. Open Terminal in Recovery and run:

   ```sh
   csrutil disable
   ```

3. Inspect the existing boot arguments:

   ```sh
   nvram boot-args
   ```

4. If no boot arguments are present, set:

   ```sh
   nvram boot-args="amfi_get_out_of_my_way=1"
   ```

   If other required arguments already exist, preserve them and append
   `amfi_get_out_of_my_way=1` to the same value.

5. Restart the guest and verify the effective settings:

   ```sh
   csrutil status
   /usr/sbin/nvram boot-args
   sudo /usr/sbin/sysctl kern.bootargs
   ```

   SIP should report `disabled`, and both boot-argument outputs should contain
   `amfi_get_out_of_my_way=1`. macOS 15 uses the same steps as macOS 14 for the
   tested package.

## Start the guest receiver

1. Open the **Virtual Mac Guest Tools** menu in the guest menu bar.
2. Choose **Open Gamepad Script Folder**.
3. Double-click **Start VirtualMac Gamepad.command**.
4. Choose **Virtio Socket** and enter the guest administrator password when
   Terminal requests it.
5. Keep the Terminal window open. The receiver is ready when it reports that it
   is listening and the virtual gamepad is `active`. Press Control-C to stop it.

## Enable forwarding on the iPad

1. Open Virtual Mac **Settings** and select **Gamepad Relay**.
2. Leave **Enable UDP compatibility mode** switched off. No guest address is
   required for Virtio Socket.
3. Check the live input display. Buttons, sticks, triggers, and the D-pad should
   follow the physical controller before forwarding is enabled.
4. Enable continuous gamepad forwarding and operate the controller.
5. Confirm that the guest Terminal shows received input and increasing
   statistics.

The one-shot **Send Test State** action does not provide an observable result or
ACK over Virtio Socket in the tested package. It should not be used to decide
whether vsock forwarding works.

## Use the controller

The receiver creates a generic `VirtualMac Network Gamepad`. The native macOS
Steam client can detect it and map its buttons, D-pad, triggers, and sticks.
Wine and SDL applications can also consume the raw IOHID controls.

Steam Big Picture mode crashed in the tested guest for an unknown reason, even
though the normal Steam controller settings detected and mapped the device.

## Optional UDP compatibility mode

UDP is not required for normal use. To use it, enable **UDP compatibility
mode** in the iPad app, enter the guest IPv4 address, and choose **UDP** when
starting the guest receiver. Bridge and NAT settings affect only UDP; they do
not affect Virtio Socket.

## Current limitations

- One controller at a time.
- No vibration, gyro, touchpad, battery, controller audio, or multi-controller
  support.
- The receiver must be started manually after each guest boot and requires the
  guest administrator password.
- The one-shot test action is ineffective over Virtio Socket; use continuous
  forwarding.
- Applications that rely only on macOS `GameController.framework` may not see
  the virtual HID. Steam Input and raw IOHID/SDL/Wine are the intended paths.
- UDP has no authentication or encryption.
