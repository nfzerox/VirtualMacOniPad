#ifndef VZ_USB_RESTORE_BRIDGE_H
#define VZ_USB_RESTORE_BRIDGE_H

#include <stdint.h>
#include "VZPaths.h"

#define VZ_USB_BRIDGE_SOCKET VZSocketPath("vz-usb-restore.sock")
#define VZ_USB_BRIDGE_MAGIC 0x565a5553U
#define VZ_USB_BRIDGE_VERSION 2U
#define VZ_USB_BRIDGE_MAX_PAYLOAD (64U * 1024U * 1024U)

enum vz_usb_bridge_operation {
    VZ_USB_BRIDGE_GET_STATE = 1,
    VZ_USB_BRIDGE_CONTROL = 2,
    VZ_USB_BRIDGE_BULK = 3,
    VZ_USB_BRIDGE_RESET = 4,
    VZ_USB_BRIDGE_CREATE_ENDPOINT = 5,
};

struct vz_usb_bridge_request {
    uint32_t magic;
    uint16_t version;
    uint16_t operation;
    uint32_t payload_length;
    uint32_t timeout_ms;
    uint8_t request_type;
    uint8_t request;
    uint16_t value;
    uint16_t index;
    uint16_t length;
    uint8_t endpoint;
    uint8_t reserved[3];
    uint32_t transfer_length;
};

struct vz_usb_bridge_response {
    uint32_t magic;
    int32_t status;
    uint32_t payload_length;
    uint32_t device_generation;
    uint16_t vendor_id;
    uint16_t product_id;
    uint8_t device_address;
    uint8_t ready;
    uint8_t reserved[6];
};

#endif
