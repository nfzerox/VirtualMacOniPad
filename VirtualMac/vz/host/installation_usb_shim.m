#include "VZPaths.h"
// Publish VMM's real AVP-backed restore USB device to MobileDevice without
// requiring macOS's AppleUSBUserHCIResources kernel service.  MobileDevice
// continues to use iPadOS's native IOUSBLib; only IOKit registry/user-client
// calls for our synthetic handles are redirected to the VMM socket bridge.

#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <IOKit/IOKitLib.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "usb_restore_bridge.h"

#define FAKE_USB_DEVICE_SERVICE_BASE ((io_service_t)0x766d2000)
#define FAKE_USB_DEVICE_SERVICE_LIMIT ((io_service_t)0x766d2100)
#define FAKE_USB_INTERFACE_SERVICE ((io_service_t)0x766d0002)
#define FAKE_USB_ITERATOR_BASE ((io_iterator_t)0x766d0100)
#define FAKE_USB_INTERFACE_ITERATOR ((io_iterator_t)0x766d0200)
#define FAKE_USB_CONNECTION_BASE ((io_connect_t)0x766d1000)
#define FAKE_USB_CONNECTION_LIMIT ((io_connect_t)0x766d1100)
#define FAKE_USB_INTERFACE_CONNECTION ((io_connect_t)0x766d1200)
#define FAKE_USB_POWER_CONNECTION ((io_connect_t)0x766d1300)
#define FAKE_USB_POWER_NOTIFIER ((io_object_t)0x766d1301)
#define FAKE_USB_MAX_NOTIFICATIONS 64
#define FAKE_USB_MAX_PORTS 8

typedef struct IOCFPlugInInterfaceStruct {
    IUNKNOWN_C_GUTS;
    UInt16 version;
    UInt16 revision;
    IOReturn (*Probe)(void *, CFDictionaryRef, io_service_t, SInt32 *);
    IOReturn (*Start)(void *, CFDictionaryRef, io_service_t);
    IOReturn (*Stop)(void *);
} IOCFPlugInInterface;

extern kern_return_t IOCreatePlugInInterfaceForService(
    io_service_t service, CFUUIDRef plugin_type, CFUUIDRef interface_type,
    IOCFPlugInInterface ***interface, SInt32 *score);
extern io_connect_t IORegisterForSystemPower(
    void *refcon, IONotificationPortRef *notify_port,
    IOServiceInterestCallback callback, io_object_t *notifier);
extern IOReturn IOAllowPowerChange(io_connect_t connection,
                                   intptr_t notification_id);

typedef struct {
    bool used;
    bool delivered;
    bool termination;
    bool interface;
    uint16_t product_id;
    uint32_t observed_generation;
    io_service_t delivered_service;
    IOServiceMatchingCallback callback;
    void *refcon;
    dispatch_queue_t callback_queue;
} fake_usb_notification_t;

typedef struct {
    IONotificationPortRef port;
    dispatch_queue_t queue;
} fake_usb_port_queue_t;

static fake_usb_notification_t fake_usb_notifications[
    FAKE_USB_MAX_NOTIFICATIONS];
static fake_usb_port_queue_t fake_usb_port_queues[FAKE_USB_MAX_PORTS];
static dispatch_queue_t fake_usb_notification_queue;
static dispatch_queue_t fake_usb_bulk_input_queue;
static dispatch_queue_t fake_usb_bulk_output_queue;
static bool fake_usb_notification_poller_started;
static bool fake_usb_interface_iterator_ready;
static uint32_t fake_usb_logged_configuration_generation;
static uint8_t fake_usb_selected_interface_number;
static uint8_t fake_usb_selected_interface_alternate;
static pthread_mutex_t fake_usb_configuration_lock =
    PTHREAD_MUTEX_INITIALIZER;
static uint32_t fake_usb_configured_generation;
static uint8_t fake_usb_recovery_dfu_recipient_mode;
static uint8_t fake_usb_pipe_endpoints[256];

static void usb_shim_log(const char *format, ...) {
    FILE *file = fopen(VZTemporaryPath("installation-usb.log"), "a");
    if (!file)
        return;
    va_list arguments;
    va_start(arguments, format);
    fprintf(file, "[installation-usb] pid=%d ", getpid());
    vfprintf(file, format, arguments);
    fputc('\n', file);
    va_end(arguments);
    fclose(file);
}

static bool usb_shim_trace_transfers(void) {
    const char *value = getenv("INSTALL_USB_TRACE_TRANSFERS");
    return value && value[0] != '\0' && strcmp(value, "0") != 0;
}

static void usb_shim_log_cf(const char *label, CFTypeRef object) {
    if (!object)
        return;
    CFStringRef description = CFCopyDescription(object);
    if (!description)
        return;
    char text[4096] = {0};
    if (CFStringGetCString(description, text, sizeof(text),
                          kCFStringEncodingUTF8))
        usb_shim_log("%s %s", label, text);
    CFRelease(description);
}

static void usb_shim_log_descriptor(uint16_t value, const void *data,
                                    uint32_t length) {
    if ((value >> 8) != 3 || !data || length < 2)
        return;
    const uint8_t *bytes = data;
    char text[512];
    size_t used = 0;
    for (uint32_t index = 2; index + 1 < length && used + 2 < sizeof(text);
         index += 2) {
        uint16_t character = (uint16_t)bytes[index] |
                             ((uint16_t)bytes[index + 1] << 8);
        text[used++] = character >= 0x20 && character <= 0x7e
                           ? (char)character : '?';
    }
    text[used] = '\0';
    usb_shim_log("real USB string descriptor index=%u length=%u text=%s",
                 value & 0xff, length, text);
}

static bool usb_read_full(int fd, void *buffer, size_t length) {
    uint8_t *bytes = buffer;
    while (length) {
        ssize_t count = read(fd, bytes, length);
        if (count == 0)
            return false;
        if (count < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        bytes += count;
        length -= (size_t)count;
    }
    return true;
}

static bool usb_write_full(int fd, const void *buffer, size_t length) {
    const uint8_t *bytes = buffer;
    while (length) {
        ssize_t count = write(fd, bytes, length);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            return false;
        }
        bytes += count;
        length -= (size_t)count;
    }
    return true;
}

static int usb_bridge_request(
    struct vz_usb_bridge_request *request, const void *output_payload,
    void *input_payload, uint32_t input_capacity,
    struct vz_usb_bridge_response *response) {
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, VZ_USB_BRIDGE_SOCKET,
            sizeof(address.sun_path));
    int socket_fd = -1;
    int error = 0;
    uint32_t retry_ms = request->timeout_ms;
    if (!retry_ms || retry_ms > 5000)
        retry_ms = 5000;
    for (uint32_t elapsed_ms = 0;; elapsed_ms++) {
        socket_fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (socket_fd < 0)
            return errno;
        if (connect(socket_fd, (struct sockaddr *)&address,
                    sizeof(address)) == 0)
            break;
        error = errno;
        close(socket_fd);
        socket_fd = -1;
        bool transient = error == ECONNREFUSED || error == EAGAIN ||
                         error == ENOENT;
        if (!transient || elapsed_ms >= retry_ms)
            return error;
        usleep(1000);
    }
    request->magic = VZ_USB_BRIDGE_MAGIC;
    request->version = VZ_USB_BRIDGE_VERSION;
    if (!usb_write_full(socket_fd, request, sizeof(*request)) ||
        (request->payload_length &&
         !usb_write_full(socket_fd, output_payload,
                         request->payload_length)) ||
        !usb_read_full(socket_fd, response, sizeof(*response)) ||
        response->magic != VZ_USB_BRIDGE_MAGIC) {
        close(socket_fd);
        return EIO;
    }
    if (response->payload_length) {
        if (response->payload_length > input_capacity ||
            !usb_read_full(socket_fd, input_payload,
                           response->payload_length)) {
            close(socket_fd);
            return EMSGSIZE;
        }
    }
    close(socket_fd);
    return response->status;
}

static bool usb_bridge_get_state(struct vz_usb_bridge_response *response) {
    struct vz_usb_bridge_request request = {
        .operation = VZ_USB_BRIDGE_GET_STATE,
        .timeout_ms = 1000,
    };
    memset(response, 0, sizeof(*response));
    int result = usb_bridge_request(&request, NULL, NULL, 0, response);
    return response->magic == VZ_USB_BRIDGE_MAGIC &&
           (result == 0 || result == ENODEV);
}

static bool usb_bridge_ready(void) {
    struct vz_usb_bridge_response response = {0};
    return usb_bridge_get_state(&response) && response.ready &&
           response.vendor_id == 0x05ac;
}

static uint32_t usb_bridge_read_descriptor(uint16_t value, uint16_t index,
                                           void *buffer,
                                           uint32_t capacity) {
    if (capacity > UINT16_MAX)
        capacity = UINT16_MAX;
    struct vz_usb_bridge_request request = {
        .operation = VZ_USB_BRIDGE_CONTROL,
        .timeout_ms = 30000,
        .request_type = 0x80,
        .request = 6,
        .value = value,
        .index = index,
        .length = (uint16_t)capacity,
    };
    struct vz_usb_bridge_response response = {0};
    int result = usb_bridge_request(&request, NULL, buffer, capacity,
                                    &response);
    return result ? 0 : response.payload_length;
}

static uint32_t usb_bridge_read_interface_configuration(void *buffer,
                                                        uint32_t capacity) {
    uint8_t raw[4096] = {0};
    uint32_t raw_length = usb_bridge_read_descriptor(
        0x0200, 0, raw, sizeof(raw));
    if (!raw_length)
        return 0;

    struct vz_usb_bridge_response state = {0};
    usb_bridge_get_state(&state);
    uint32_t insertion = 0;
    bool selected = false;
    bool has_functional_descriptor = false;
    for (uint32_t offset = 0; offset + 2 <= raw_length;) {
        uint8_t descriptor_length = raw[offset];
        if (descriptor_length < 2 || offset + descriptor_length > raw_length)
            break;
        uint8_t descriptor_type = raw[offset + 1];
        if (descriptor_type == 4 && descriptor_length >= 9) {
            if (selected)
                break;
            selected = raw[offset + 2] == fake_usb_selected_interface_number &&
                       raw[offset + 3] == fake_usb_selected_interface_alternate;
            if (selected)
                insertion = offset + descriptor_length;
        } else if (selected && descriptor_type == 0x21) {
            has_functional_descriptor = true;
        }
        offset += descriptor_length;
    }

    // The recovery personality's wire descriptor identifies its transfer
    // interface as DFU class but omits the DFU functional descriptor.
    // IOUSBHost publishes that host-side metadata to IOUSBLib on macOS;
    // MobileRestore uses it to obtain the transfer size before opening the
    // real bulk endpoint.  Recreate only that registry-side view, leaving all
    // control transfers and the physical descriptor stream untouched.
    static const uint8_t functional[] = { 7, 0x21, 1, 10, 0, 0, 8 };
    uint8_t hosted[sizeof(raw) + sizeof(functional)] = {0};
    const uint8_t *source = raw;
    uint32_t source_length = raw_length;
    bool should_insert = state.product_id == 0x1281 && selected &&
                         !has_functional_descriptor && insertion &&
                         raw_length + sizeof(functional) <= sizeof(hosted);
    if (should_insert) {
        memcpy(hosted, raw, insertion);
        memcpy(hosted + insertion, functional, sizeof(functional));
        memcpy(hosted + insertion + sizeof(functional), raw + insertion,
               raw_length - insertion);
        source = hosted;
        source_length = raw_length + sizeof(functional);
        hosted[2] = (uint8_t)source_length;
        hosted[3] = (uint8_t)(source_length >> 8);
    }
    uint32_t copied = source_length < capacity ? source_length : capacity;
    memcpy(buffer, source, copied);
    usb_shim_log("interface host configuration raw=%u hosted=%u "
                 "inserted-dfu=%d selected=%u/%u", raw_length,
                 source_length, should_insert,
                 fake_usb_selected_interface_number,
                 fake_usb_selected_interface_alternate);
    return copied;
}

static int usb_bridge_create_active_endpoints(void);

static int usb_bridge_set_configuration(uint8_t configuration) {
    struct vz_usb_bridge_request request = {
        .operation = VZ_USB_BRIDGE_CONTROL,
        .timeout_ms = 30000,
        .request_type = 0x00,
        .request = 9,
        .value = configuration,
    };
    struct vz_usb_bridge_response response = {0};
    return usb_bridge_request(&request, NULL, NULL, 0, &response);
}

static int usb_bridge_create_endpoint(const uint8_t *descriptor) {
    struct vz_usb_bridge_request request = {
        .operation = VZ_USB_BRIDGE_CREATE_ENDPOINT,
        .payload_length = 7,
        .timeout_ms = 30000,
        .endpoint = descriptor[2],
    };
    struct vz_usb_bridge_response response = {0};
    return usb_bridge_request(&request, descriptor, NULL, 0, &response);
}

static int usb_bridge_create_active_endpoints(void) {
    uint8_t configuration[4096] = {0};
    uint32_t length = usb_bridge_read_descriptor(
        0x0200, 0, configuration, sizeof(configuration));
    bool active = false;
    int result = 0;
    for (uint32_t offset = 0; offset + 2 <= length;) {
        uint8_t descriptor_length = configuration[offset];
        if (descriptor_length < 2 || offset + descriptor_length > length)
            break;
        uint8_t descriptor_type = configuration[offset + 1];
        if (descriptor_type == 4 && descriptor_length >= 9) {
            uint8_t number = configuration[offset + 2];
            uint8_t alternate = configuration[offset + 3];
            active = alternate == 0 ||
                     (number == fake_usb_selected_interface_number &&
                      alternate == fake_usb_selected_interface_alternate);
        } else if (active && descriptor_type == 5 &&
                   descriptor_length >= 7) {
            result = usb_bridge_create_endpoint(configuration + offset);
            usb_shim_log("created real USB endpoint=0x%02x -> %d",
                         configuration[offset + 2], result);
            if (result)
                return result;
        }
        offset += descriptor_length;
    }
    return result;
}

static bool usb_bridge_endpoint_for_pipe(uint8_t wanted_pipe,
                                         uint8_t *endpoint) {
    if (fake_usb_pipe_endpoints[wanted_pipe]) {
        *endpoint = fake_usb_pipe_endpoints[wanted_pipe];
        return true;
    }
    uint8_t configuration[4096] = {0};
    uint32_t configuration_length = usb_bridge_read_descriptor(
        0x0200, 0, configuration, sizeof(configuration));
    uint8_t pipe = 0;
    bool selected = false;
    for (uint32_t offset = 0; offset + 2 <= configuration_length;) {
        uint8_t descriptor_length = configuration[offset];
        if (descriptor_length < 2 ||
            offset + descriptor_length > configuration_length)
            break;
        uint8_t descriptor_type = configuration[offset + 1];
        if (descriptor_type == 4 && descriptor_length >= 9) {
            selected = configuration[offset + 2] ==
                           fake_usb_selected_interface_number &&
                       configuration[offset + 3] ==
                           fake_usb_selected_interface_alternate;
            pipe = 0;
        } else if (selected && descriptor_type == 5 &&
                   descriptor_length >= 7) {
            pipe++;
            if (pipe == wanted_pipe) {
                *endpoint = configuration[offset + 2];
                fake_usb_pipe_endpoints[wanted_pipe] = *endpoint;
                return true;
            }
        }
        offset += descriptor_length;
    }
    return false;
}

static int usb_bridge_bulk_transfer(uint8_t endpoint, void *buffer,
                                    uint32_t length, uint32_t timeout_ms,
                                    uint32_t *actual_length) {
    bool input = (endpoint & 0x80U) != 0;
    struct vz_usb_bridge_request request = {
        .operation = VZ_USB_BRIDGE_BULK,
        .payload_length = input ? 0 : length,
        .timeout_ms = timeout_ms ?: 30000,
        .endpoint = endpoint,
        .transfer_length = length,
    };
    struct vz_usb_bridge_response response = {0};
    int result = usb_bridge_request(
        &request, input ? NULL : buffer, input ? buffer : NULL,
        input ? length : 0, &response);
    if (!result && actual_length)
        *actual_length = input ? response.payload_length : length;
    if (result || usb_shim_trace_transfers())
        usb_shim_log("bulk endpoint=0x%02x direction=%s length=%u -> %d "
                     "actual=%u", endpoint, input ? "in" : "out", length,
                     result, response.payload_length);
    return result;
}

static bool usb_bridge_configure_generation(uint32_t generation) {
    pthread_mutex_lock(&fake_usb_configuration_lock);
    if (fake_usb_configured_generation == generation) {
        pthread_mutex_unlock(&fake_usb_configuration_lock);
        return true;
    }
    uint8_t descriptor[9] = {0};
    uint32_t actual = usb_bridge_read_descriptor(
        0x0200, 0, descriptor, sizeof(descriptor));
    uint8_t configuration = actual >= sizeof(descriptor) &&
                            descriptor[1] == 2
                                ? descriptor[5] : 1;
    int result = usb_bridge_set_configuration(configuration);
    if (!result)
        result = usb_bridge_create_active_endpoints();
    if (!result)
        fake_usb_configured_generation = generation;
    pthread_mutex_unlock(&fake_usb_configuration_lock);
    usb_shim_log("configured real USB generation=%u value=%u -> %d",
                 generation, configuration, result);
    return result == 0;
}

static CFStringRef usb_bridge_copy_string_descriptor(uint8_t index) {
    uint8_t descriptor[255] = {0};
    uint32_t actual = usb_bridge_read_descriptor(
        (uint16_t)(0x0300U | index), 0x0409, descriptor,
        sizeof(descriptor));
    if (actual < 2 || descriptor[1] != 3)
        return NULL;
    uint32_t length = descriptor[0];
    if (length > actual)
        length = actual;
    if (length < 2)
        return NULL;
    CFStringRef string = CFStringCreateWithBytes(
        kCFAllocatorDefault, descriptor + 2, (CFIndex)(length - 2),
        kCFStringEncodingUTF16LE, false);
    usb_shim_log_descriptor((uint16_t)(0x0300U | index), descriptor,
                            length);
    return string;
}

static bool is_fake_usb_service(io_object_t object) {
    return (object >= FAKE_USB_DEVICE_SERVICE_BASE &&
            object < FAKE_USB_DEVICE_SERVICE_LIMIT) ||
           object == FAKE_USB_INTERFACE_SERVICE;
}

static io_service_t fake_usb_device_service(uint32_t generation) {
    return FAKE_USB_DEVICE_SERVICE_BASE + (generation & 0xffU);
}

static uint32_t fake_usb_service_generation(io_object_t object) {
    return object >= FAKE_USB_DEVICE_SERVICE_BASE &&
           object < FAKE_USB_DEVICE_SERVICE_LIMIT
               ? object - FAKE_USB_DEVICE_SERVICE_BASE : 0;
}

static bool is_fake_usb_device_connection(io_connect_t connection) {
    return connection > FAKE_USB_CONNECTION_BASE &&
           connection < FAKE_USB_CONNECTION_LIMIT;
}

static uint32_t fake_usb_connection_generation(io_connect_t connection) {
    return is_fake_usb_device_connection(connection)
               ? connection - FAKE_USB_CONNECTION_BASE : 0;
}

static bool fake_usb_connection_is_current(io_connect_t connection) {
    struct vz_usb_bridge_response state = {0};
    uint32_t generation = fake_usb_connection_generation(connection);
    bool current = generation && usb_bridge_get_state(&state) && state.ready &&
                   state.device_generation == generation;
    if (!current)
        usb_shim_log("rejected stale USB device connection=0x%x "
                     "generation=%u current=%u ready=%u", connection,
                     generation, state.device_generation, state.ready);
    return current;
}

static int notification_index(io_iterator_t iterator) {
    uint32_t value = (uint32_t)iterator;
    if (value < FAKE_USB_ITERATOR_BASE ||
        value >= FAKE_USB_ITERATOR_BASE + FAKE_USB_MAX_NOTIFICATIONS)
        return -1;
    return (int)(value - FAKE_USB_ITERATOR_BASE);
}

static bool matching_wants_usb(CFDictionaryRef matching,
                               uint16_t *wanted_product,
                               bool *wanted_interface) {
    if (!matching)
        return false;
    CFTypeRef value = CFDictionaryGetValue(
        matching, CFSTR("IOProviderClass"));
    if (!value || CFGetTypeID(value) != CFStringGetTypeID())
        return false;
    bool usb_device_class =
        CFStringCompare(value, CFSTR("IOUSBDevice"), 0) ==
            kCFCompareEqualTo ||
        CFStringCompare(value, CFSTR("IOUSBHostDevice"), 0) ==
            kCFCompareEqualTo;
    bool usb_interface_class =
        CFStringCompare(value, CFSTR("IOUSBInterface"), 0) ==
            kCFCompareEqualTo ||
        CFStringCompare(value, CFSTR("IOUSBHostInterface"), 0) ==
            kCFCompareEqualTo;
    if (!usb_device_class && !usb_interface_class)
        return false;
    CFTypeRef product = CFDictionaryGetValue(matching, CFSTR("idProduct"));
    if (!product) {
        CFTypeRef property_match = CFDictionaryGetValue(
            matching, CFSTR("IOPropertyMatch"));
        if (property_match &&
            CFGetTypeID(property_match) == CFDictionaryGetTypeID())
            product = CFDictionaryGetValue(
                (CFDictionaryRef)property_match, CFSTR("idProduct"));
    }
    int32_t product_id = 0x12ac;
    bool product_matches = usb_interface_class;
    if (product && CFGetTypeID(product) == CFNumberGetTypeID() &&
        CFNumberGetValue((CFNumberRef)product, kCFNumberSInt32Type,
                         &product_id) && product_id >= 0 &&
        product_id <= UINT16_MAX) {
        product_matches = true;
    } else if (usb_device_class) {
        CFTypeRef products = CFDictionaryGetValue(
            matching, CFSTR("idProductArray"));
        if (products && CFGetTypeID(products) == CFArrayGetTypeID()) {
            CFIndex count = CFArrayGetCount((CFArrayRef)products);
            for (CFIndex index = 0; index < count; index++) {
                CFTypeRef item = CFArrayGetValueAtIndex(
                    (CFArrayRef)products, index);
                int32_t candidate = 0;
                if (item && CFGetTypeID(item) == CFNumberGetTypeID() &&
                    CFNumberGetValue((CFNumberRef)item,
                                     kCFNumberSInt32Type, &candidate) &&
                    candidate == 0x12ac) {
                    product_matches = true;
                    break;
                }
            }
        }
    }
    if (!product_matches)
        return false;
    CFTypeRef vendor = CFDictionaryGetValue(matching, CFSTR("idVendor"));
    if (!vendor) {
        CFTypeRef property_match = CFDictionaryGetValue(
            matching, CFSTR("IOPropertyMatch"));
        if (property_match &&
            CFGetTypeID(property_match) == CFDictionaryGetTypeID())
            vendor = CFDictionaryGetValue(
                (CFDictionaryRef)property_match, CFSTR("idVendor"));
    }
    int32_t vendor_id = 0x05ac;
    if (vendor && (CFGetTypeID(vendor) != CFNumberGetTypeID() ||
                   !CFNumberGetValue((CFNumberRef)vendor,
                                     kCFNumberSInt32Type, &vendor_id)))
        return false;
    if (vendor_id != 0x05ac)
        return false;
    if (usb_interface_class) {
        int32_t interface_class = 0;
        int32_t interface_subclass = 0;
        int32_t interface_protocol = 0;
        CFTypeRef class_value = CFDictionaryGetValue(
            matching, CFSTR("bInterfaceClass"));
        CFTypeRef subclass_value = CFDictionaryGetValue(
            matching, CFSTR("bInterfaceSubClass"));
        CFTypeRef protocol_value = CFDictionaryGetValue(
            matching, CFSTR("bInterfaceProtocol"));
        if (!class_value || !subclass_value || !protocol_value ||
            CFGetTypeID(class_value) != CFNumberGetTypeID() ||
            CFGetTypeID(subclass_value) != CFNumberGetTypeID() ||
            CFGetTypeID(protocol_value) != CFNumberGetTypeID() ||
            !CFNumberGetValue((CFNumberRef)class_value,
                              kCFNumberSInt32Type, &interface_class) ||
            !CFNumberGetValue((CFNumberRef)subclass_value,
                              kCFNumberSInt32Type, &interface_subclass) ||
            !CFNumberGetValue((CFNumberRef)protocol_value,
                              kCFNumberSInt32Type, &interface_protocol) ||
            interface_class != 0xff || interface_subclass != 0xfe ||
            interface_protocol != 2)
            return false;
    }
    *wanted_product = usb_interface_class ? 0x12ac
                                          : (uint16_t)product_id;
    *wanted_interface = usb_interface_class;
    return true;
}

static CFMutableDictionaryRef fake_usb_properties(bool interface) {
    CFMutableDictionaryRef properties = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    struct vz_usb_bridge_response state = {0};
    usb_bridge_get_state(&state);
    uint8_t device[18] = {0};
    uint8_t configuration[4096] = {0};
    uint32_t device_length = usb_bridge_read_descriptor(
        0x0100, 0, device, sizeof(device));
    uint32_t configuration_length = usb_bridge_read_descriptor(
        0x0200, 0, configuration, sizeof(configuration));
    if (configuration_length &&
        fake_usb_logged_configuration_generation != state.device_generation) {
        char bytes[3 * 128 + 1] = {0};
        size_t cursor = 0;
        uint32_t shown = configuration_length < 128
            ? configuration_length : 128;
        for (uint32_t index = 0; index < shown; index++) {
            int count = snprintf(bytes + cursor, sizeof(bytes) - cursor,
                                 "%02x%s", configuration[index],
                                 index + 1 == shown ? "" : " ");
            if (count < 0 || (size_t)count >= sizeof(bytes) - cursor)
                break;
            cursor += (size_t)count;
        }
        usb_shim_log("real USB configuration generation=%u length=%u: %s",
                     state.device_generation, configuration_length, bytes);
        fake_usb_logged_configuration_generation = state.device_generation;
    }
    uint16_t vendor_id = state.vendor_id ?: 0x05ac;
    uint16_t product_id = state.product_id;
    uint16_t bcd_usb = 0x0200;
    uint16_t bcd_device = 0;
    uint8_t device_class = 0;
    uint8_t device_subclass = 0;
    uint8_t device_protocol = 0;
    uint8_t max_packet_size = 64;
    uint8_t manufacturer_index = 2;
    uint8_t product_index = 3;
    uint8_t serial_index = 4;
    uint8_t configuration_count = 1;
    if (device_length >= sizeof(device) && device[1] == 1) {
        bcd_usb = (uint16_t)device[2] | ((uint16_t)device[3] << 8);
        device_class = device[4];
        device_subclass = device[5];
        device_protocol = device[6];
        max_packet_size = device[7];
        vendor_id = (uint16_t)device[8] | ((uint16_t)device[9] << 8);
        product_id = (uint16_t)device[10] | ((uint16_t)device[11] << 8);
        bcd_device = (uint16_t)device[12] | ((uint16_t)device[13] << 8);
        manufacturer_index = device[14];
        product_index = device[15];
        serial_index = device[16];
        configuration_count = device[17];
    }
    uint8_t interface_class = 0;
    uint8_t interface_subclass = 0;
    uint8_t interface_protocol = 0;
    uint8_t interface_number = 0;
    uint8_t alternate_setting = 0;
    uint8_t endpoint_count = 0;
    uint8_t interface_index = 0;
    for (uint32_t offset = 0; offset + 2 <= configuration_length;) {
        uint8_t descriptor_length = configuration[offset];
        if (descriptor_length < 2 || offset + descriptor_length >
                                       configuration_length)
            break;
        if (configuration[offset + 1] == 4 && descriptor_length >= 9 &&
            (!interface ||
             (configuration[offset + 2] ==
                  fake_usb_selected_interface_number &&
              configuration[offset + 3] ==
                  fake_usb_selected_interface_alternate))) {
            interface_number = configuration[offset + 2];
            alternate_setting = configuration[offset + 3];
            endpoint_count = configuration[offset + 4];
            interface_class = configuration[offset + 5];
            interface_subclass = configuration[offset + 6];
            interface_protocol = configuration[offset + 7];
            interface_index = configuration[offset + 8];
            break;
        }
        offset += descriptor_length;
    }
    struct { const char *key; int32_t value; } numbers[] = {
        { "locationID", (int32_t)0x80100000U },
        { "idVendor", vendor_id }, { "idProduct", product_id },
        { "bDeviceClass", device_class },
        { "bDeviceSubClass", device_subclass },
        { "bDeviceProtocol", device_protocol },
        { "bMaxPacketSize0", max_packet_size },
        { "bcdUSB", bcd_usb }, { "bcdDevice", bcd_device },
        { "iManufacturer", manufacturer_index },
        { "iProduct", product_index },
        { "iSerialNumber", serial_index },
        { "bNumConfigurations", configuration_count },
        { "kUSBAddress", state.device_address },
        { "USB Address", state.device_address },
        { "Device Speed", 3 }, { "kUSBCurrentConfiguration", 0 },
    };
    for (size_t index = 0; index < sizeof(numbers) / sizeof(numbers[0]);
         index++) {
        CFStringRef key = CFStringCreateWithCString(
            kCFAllocatorDefault, numbers[index].key,
            kCFStringEncodingUTF8);
        CFNumberRef number = CFNumberCreate(
            kCFAllocatorDefault, kCFNumberSInt32Type,
            &numbers[index].value);
        CFDictionarySetValue(properties, key, number);
        CFRelease(number);
        CFRelease(key);
    }
    CFStringRef vendor = usb_bridge_copy_string_descriptor(
        manufacturer_index);
    CFStringRef product = usb_bridge_copy_string_descriptor(product_index);
    CFStringRef serial = usb_bridge_copy_string_descriptor(serial_index);
    CFDictionarySetValue(properties, CFSTR("USB Product Name"),
                         product ?: CFSTR("Apple Virtual Restore Device"));
    CFDictionarySetValue(properties, CFSTR("USB Vendor Name"),
                         vendor ?: CFSTR("Apple Inc."));
    if (serial)
        CFDictionarySetValue(properties, CFSTR("USB Serial Number"), serial);
    if (vendor)
        CFRelease(vendor);
    if (product)
        CFRelease(product);
    if (serial)
        CFRelease(serial);
    CFDictionarySetValue(properties, CFSTR("IOClass"),
                         interface ? CFSTR("IOUSBHostInterface")
                                   : CFSTR("IOUSBHostDevice"));
    if (interface) {
        struct { const char *key; int32_t value; } interface_numbers[] = {
            { "bInterfaceClass", interface_class },
            { "bInterfaceSubClass", interface_subclass },
            { "bInterfaceProtocol", interface_protocol },
            { "bInterfaceNumber", interface_number },
            { "bAlternateSetting", alternate_setting },
            { "bNumEndpoints", endpoint_count },
            { "iInterface", interface_index },
        };
        for (size_t index = 0;
             index < sizeof(interface_numbers) / sizeof(interface_numbers[0]);
             index++) {
            CFStringRef key = CFStringCreateWithCString(
                kCFAllocatorDefault, interface_numbers[index].key,
                kCFStringEncodingUTF8);
            CFNumberRef number = CFNumberCreate(
                kCFAllocatorDefault, kCFNumberSInt32Type,
                &interface_numbers[index].value);
            CFDictionarySetValue(properties, key, number);
            CFRelease(number);
            CFRelease(key);
        }
    }
    return properties;
}

static void fake_usb_deliver_notification(unsigned index) {
    if (index >= FAKE_USB_MAX_NOTIFICATIONS)
        return;
    fake_usb_notification_t *notification = &fake_usb_notifications[index];
    if (!notification->used || notification->delivered ||
        !notification->callback)
        return;
    notification->delivered = true;
    usb_shim_log("delivering %s notification %u product=0x%04x on "
                 "queue=%s",
                 notification->termination ? "termination" : "matched",
                 index, notification->product_id,
                 notification->callback_queue
                    ? dispatch_queue_get_label(notification->callback_queue)
                    : "(none)");
    notification->callback(notification->refcon,
                           FAKE_USB_ITERATOR_BASE + index);
}

static void fake_usb_deliver_on_registered_queue(unsigned index) {
    dispatch_queue_t callback_queue =
        fake_usb_notifications[index].callback_queue;
    if (callback_queue) {
        dispatch_sync(callback_queue, ^{
            fake_usb_deliver_notification(index);
        });
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            fake_usb_deliver_notification(index);
        });
    }
}

static void fake_usb_deliver_prior_terminations(
    const struct vz_usb_bridge_response *state) {
    // IOKit publishes removal of the old personality before matching the
    // newly enumerated one.  MobileRestore uses that ordering to retire its
    // DFU state machine before accepting iBoot recovery.  Independent polling
    // workers used to race and deliver recovery first, which made the DFU
    // worker try to send iBEC with DFU requests to the recovery interface.
    for (unsigned index = 0; index < FAKE_USB_MAX_NOTIFICATIONS; index++) {
        fake_usb_notification_t *notification =
            &fake_usb_notifications[index];
        if (!notification->used || !notification->termination ||
            !notification->observed_generation)
            continue;
        bool still_matches = state->ready && state->vendor_id == 0x05ac &&
                             state->product_id == notification->product_id &&
                             state->device_generation ==
                                 notification->observed_generation;
        if (still_matches)
            continue;
        notification->delivered_service = fake_usb_device_service(
            notification->observed_generation);
        notification->observed_generation = 0;
        usb_shim_log("ordering termination %u product=0x%04x before "
                     "generation=%u product=0x%04x", index,
                     notification->product_id, state->device_generation,
                     state->product_id);
        fake_usb_deliver_on_registered_queue(index);
    }
}

static void fake_usb_start_notification_poller(void) {
    if (__atomic_exchange_n(&fake_usb_notification_poller_started, true,
                            __ATOMIC_ACQ_REL))
        return;
    dispatch_async(fake_usb_notification_queue, ^{
        const char *poll_text = getenv("INSTALL_USB_POLL_US");
        useconds_t poll_interval = poll_text
            ? (useconds_t)strtoul(poll_text, NULL, 0) : 250000;
        if (poll_interval < 1000)
            poll_interval = 1000;
        const char *enable_file = getenv("INSTALL_USB_ENABLE_FILE");
        while (enable_file && access(enable_file, F_OK) != 0)
            usleep(1000);
        for (;;) {
            struct vz_usb_bridge_response state = {0};
            bool have_state = usb_bridge_get_state(&state);
            for (unsigned index = 0; index < FAKE_USB_MAX_NOTIFICATIONS;
                 index++) {
                fake_usb_notification_t *notification =
                    &fake_usb_notifications[index];
                if (!notification->used)
                    continue;
                bool matches = have_state && state.ready &&
                               state.vendor_id == 0x05ac &&
                               state.product_id == notification->product_id;
                bool should_deliver = false;
                if (!notification->termination && matches &&
                    state.device_generation !=
                        notification->observed_generation) {
                    notification->observed_generation =
                        state.device_generation;
                    notification->delivered_service =
                        fake_usb_device_service(state.device_generation);
                    should_deliver = true;
                } else if (notification->termination) {
                    if (!notification->observed_generation && matches) {
                        notification->observed_generation =
                            state.device_generation;
                    } else if (notification->observed_generation &&
                               have_state &&
                               (!matches || state.device_generation !=
                                    notification->observed_generation)) {
                        notification->delivered_service =
                            fake_usb_device_service(
                                notification->observed_generation);
                        notification->observed_generation = 0;
                        should_deliver = true;
                    }
                }
                if (should_deliver && !notification->termination &&
                    notification->product_id != 0x12ac &&
                    !usb_bridge_configure_generation(
                        state.device_generation)) {
                    notification->observed_generation = 0;
                    should_deliver = false;
                }
                if (should_deliver) {
                    if (!notification->termination)
                        fake_usb_deliver_prior_terminations(&state);
                    const char *debug_delay = getenv(
                        "INSTALL_USB_DEBUG_DELAY_MS");
                    if (debug_delay && !notification->termination) {
                        unsigned milliseconds = (unsigned)strtoul(
                            debug_delay, NULL, 0);
                        usb_shim_log("delaying DFU notification %u ms for "
                                     "debugger", milliseconds);
                        usleep((useconds_t)milliseconds * 1000U);
                    }
                    dispatch_queue_t callback_queue =
                        fake_usb_notifications[index].callback_queue;
                    if (callback_queue) {
                        dispatch_async(callback_queue, ^{
                            fake_usb_deliver_notification(index);
                        });
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            fake_usb_deliver_notification(index);
                        });
                    }
                }
            }
            usleep(poll_interval);
        }
    });
}

static kern_return_t shim_IOServiceAddMatchingNotification(
    IONotificationPortRef notify_port, const io_name_t notification_type,
    CFDictionaryRef matching, IOServiceMatchingCallback callback,
    void *refcon, io_iterator_t *iterator) {
    usb_shim_log_cf("IOServiceAddMatchingNotification", matching);
    uint16_t wanted_product = 0;
    bool wanted_interface = false;
    if (!matching_wants_usb(matching, &wanted_product,
                            &wanted_interface))
        return IOServiceAddMatchingNotification(
            notify_port, notification_type, matching, callback, refcon,
            iterator);
    usb_shim_log("matching notification type=%s product=0x%04x "
                 "interface=%d dictionary=%p", notification_type,
                 wanted_product, wanted_interface, matching);
    CFRelease(matching);
    for (unsigned index = 0; index < FAKE_USB_MAX_NOTIFICATIONS; index++) {
        if (!fake_usb_notifications[index].used) {
            bool termination = strstr(notification_type, "Terminate") != NULL;
            dispatch_queue_t callback_queue = NULL;
            for (unsigned port_index = 0; port_index < FAKE_USB_MAX_PORTS;
                 port_index++) {
                if (fake_usb_port_queues[port_index].port == notify_port) {
                    callback_queue = fake_usb_port_queues[port_index].queue;
                    break;
                }
            }
            fake_usb_notifications[index] = (fake_usb_notification_t){
                .used = true, .termination = termination,
                .interface = wanted_interface,
                .product_id = wanted_product,
                .callback = callback, .refcon = refcon,
                .callback_queue = callback_queue,
            };
            *iterator = FAKE_USB_ITERATOR_BASE + index;
            fake_usb_start_notification_poller();
            return KERN_SUCCESS;
        }
    }
    return kIOReturnNoResources;
}

static kern_return_t shim_IOServiceGetMatchingServices(
    mach_port_t main_port, CFDictionaryRef matching,
    io_iterator_t *iterator) {
    usb_shim_log_cf("IOServiceGetMatchingServices", matching);
    return IOServiceGetMatchingServices(main_port, matching, iterator);
}

static void shim_IONotificationPortSetDispatchQueue(
    IONotificationPortRef notify_port, dispatch_queue_t queue) {
    for (unsigned index = 0; index < FAKE_USB_MAX_PORTS; index++) {
        if (!fake_usb_port_queues[index].port ||
            fake_usb_port_queues[index].port == notify_port) {
            fake_usb_port_queues[index] = (fake_usb_port_queue_t){
                .port = notify_port, .queue = queue,
            };
            break;
        }
    }
    usb_shim_log("notification port=%p queue=%s", notify_port,
                 queue ? dispatch_queue_get_label(queue) : "(none)");
    IONotificationPortSetDispatchQueue(notify_port, queue);
}

static io_object_t shim_IOIteratorNext(io_iterator_t iterator) {
    if (iterator == FAKE_USB_INTERFACE_ITERATOR) {
        if (!fake_usb_interface_iterator_ready)
            return IO_OBJECT_NULL;
        fake_usb_interface_iterator_ready = false;
        usb_shim_log("interface iterator returned real DFU interface facade");
        return FAKE_USB_INTERFACE_SERVICE;
    }
    int index = notification_index(iterator);
    if (index < 0)
        return IOIteratorNext(iterator);
    fake_usb_notification_t *notification = &fake_usb_notifications[index];
    if (notification->delivered) {
        notification->delivered = false;
        if (notification->interface) {
            usb_shim_log("iterator %d returned RestoreOS USBMux "
                         "interface facade", index);
            return FAKE_USB_INTERFACE_SERVICE;
        }
        usb_shim_log("iterator %d returned restore service=0x%x "
                     "generation=%u", index,
                     notification->delivered_service,
                     fake_usb_service_generation(
                         notification->delivered_service));
        return notification->delivered_service;
    }
    return IO_OBJECT_NULL;
}

static kern_return_t shim_IORegistryEntryGetParentEntry(
    io_registry_entry_t entry, const io_name_t plane,
    io_registry_entry_t *parent) {
    (void)plane;
    if (entry != FAKE_USB_INTERFACE_SERVICE)
        return IORegistryEntryGetParentEntry(entry, plane, parent);
    struct vz_usb_bridge_response state = {0};
    if (!parent || !usb_bridge_get_state(&state) || !state.ready)
        return kIOReturnNotFound;
    *parent = fake_usb_device_service(state.device_generation);
    usb_shim_log("returned real RestoreOS device parent for interface");
    return KERN_SUCCESS;
}

static kern_return_t shim_IOServiceAddInterestNotification(
    IONotificationPortRef notify_port, io_service_t service,
    const io_name_t interest_type, IOServiceInterestCallback callback,
    void *refcon, io_object_t *notification) {
    (void)notify_port;
    (void)interest_type;
    (void)callback;
    (void)refcon;
    if (!is_fake_usb_service(service))
        return IOServiceAddInterestNotification(
            notify_port, service, interest_type, callback, refcon,
            notification);
    if (notification)
        *notification = FAKE_USB_POWER_NOTIFIER;
    usb_shim_log("registered RestoreOS interface interest notification");
    return KERN_SUCCESS;
}

static kern_return_t shim_IOObjectRetain(io_object_t object) {
    if (is_fake_usb_service(object) || notification_index(object) >= 0 ||
        object == FAKE_USB_INTERFACE_ITERATOR ||
        is_fake_usb_device_connection(object) ||
        object == FAKE_USB_INTERFACE_CONNECTION ||
        object == FAKE_USB_POWER_CONNECTION ||
        object == FAKE_USB_POWER_NOTIFIER)
        return KERN_SUCCESS;
    return IOObjectRetain(object);
}

static kern_return_t shim_IOObjectRelease(io_object_t object) {
    if (is_fake_usb_service(object) || notification_index(object) >= 0 ||
        object == FAKE_USB_INTERFACE_ITERATOR ||
        is_fake_usb_device_connection(object) ||
        object == FAKE_USB_INTERFACE_CONNECTION ||
        object == FAKE_USB_POWER_CONNECTION ||
        object == FAKE_USB_POWER_NOTIFIER)
        return KERN_SUCCESS;
    return IOObjectRelease(object);
}

static boolean_t shim_IOObjectConformsTo(io_object_t object,
                                         const io_name_t class_name) {
    if (!is_fake_usb_service(object))
        return IOObjectConformsTo(object, class_name);
    if (object == FAKE_USB_INTERFACE_SERVICE)
        return strcmp(class_name, "IOUSBInterface") == 0 ||
               strcmp(class_name, "IOUSBHostInterface") == 0 ||
               strcmp(class_name, "IOService") == 0;
    return strcmp(class_name, "IOUSBDevice") == 0 ||
           strcmp(class_name, "IOUSBHostDevice") == 0 ||
           strcmp(class_name, "IOService") == 0;
}

static kern_return_t shim_IORegistryEntryCreateCFProperties(
    io_registry_entry_t entry, CFMutableDictionaryRef *properties,
    CFAllocatorRef allocator, IOOptionBits options) {
    (void)allocator; (void)options;
    if (!is_fake_usb_service(entry))
        return IORegistryEntryCreateCFProperties(
            entry, properties, allocator, options);
    *properties = fake_usb_properties(entry == FAKE_USB_INTERFACE_SERVICE);
    usb_shim_log("returned real DFU %s registry properties",
                 entry == FAKE_USB_INTERFACE_SERVICE ? "interface" : "device");
    return KERN_SUCCESS;
}

static CFTypeRef shim_IORegistryEntryCreateCFProperty(
    io_registry_entry_t entry, CFStringRef key, CFAllocatorRef allocator,
    IOOptionBits options) {
    if (!is_fake_usb_service(entry))
        return IORegistryEntryCreateCFProperty(entry, key, allocator,
                                               options);
    CFMutableDictionaryRef properties = fake_usb_properties(
        entry == FAKE_USB_INTERFACE_SERVICE);
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    if (value)
        CFRetain(value);
    CFRelease(properties);
    return value;
}

static kern_return_t shim_IORegistryEntryGetName(
    io_registry_entry_t entry, io_name_t name) {
    if (!is_fake_usb_service(entry))
        return IORegistryEntryGetName(entry, name);
    strlcpy(name, entry == FAKE_USB_INTERFACE_SERVICE
                      ? "Apple Virtual DFU Interface"
                      : "Apple Virtual DFU Device",
            sizeof(io_name_t));
    return KERN_SUCCESS;
}

static kern_return_t shim_IORegistryEntryGetNameInPlane(
    io_registry_entry_t entry, const io_name_t plane, io_name_t name) {
    (void)plane;
    return shim_IORegistryEntryGetName(entry, name);
}

static kern_return_t shim_IORegistryEntryGetRegistryEntryID(
    io_registry_entry_t entry, uint64_t *entry_id) {
    if (!is_fake_usb_service(entry))
        return IORegistryEntryGetRegistryEntryID(entry, entry_id);
    *entry_id = entry == FAKE_USB_INTERFACE_SERVICE
                    ? 0x766d00020000ULL
                    : 0x766d20000000ULL |
                          fake_usb_service_generation(entry);
    return KERN_SUCCESS;
}

static kern_return_t shim_IOServiceOpen(
    io_service_t service, task_port_t owning_task, uint32_t type,
    io_connect_t *connection) {
    (void)owning_task;
    if (!is_fake_usb_service(service))
        return IOServiceOpen(service, owning_task, type, connection);
    *connection = service == FAKE_USB_INTERFACE_SERVICE
                      ? FAKE_USB_INTERFACE_CONNECTION
                      : FAKE_USB_CONNECTION_BASE +
                            fake_usb_service_generation(service);
    usb_shim_log("opened real DFU %s facade type=%u",
                 service == FAKE_USB_INTERFACE_SERVICE
                      ? "interface" : "device", type);
    return KERN_SUCCESS;
}

static kern_return_t shim_IOServiceClose(io_connect_t connection) {
    if (is_fake_usb_device_connection(connection) ||
        connection == FAKE_USB_INTERFACE_CONNECTION ||
        connection == FAKE_USB_POWER_CONNECTION)
        return KERN_SUCCESS;
    return IOServiceClose(connection);
}

static io_connect_t shim_IORegisterForSystemPower(
    void *refcon, IONotificationPortRef *notify_port,
    IOServiceInterestCallback callback, io_object_t *notifier) {
    (void)refcon;
    (void)callback;
    if (!notify_port || !notifier)
        return MACH_PORT_NULL;
    // kIOMainPortDefault was named kIOMasterPortDefault before iPadOS 15;
    // both public constants are MACH_PORT_NULL. Use the ABI value directly.
    *notify_port = IONotificationPortCreate(MACH_PORT_NULL);
    if (!*notify_port)
        return MACH_PORT_NULL;
    *notifier = FAKE_USB_POWER_NOTIFIER;
    usb_shim_log("supplied userspace system-power notification facade");
    return FAKE_USB_POWER_CONNECTION;
}

static IOReturn shim_IOAllowPowerChange(io_connect_t connection,
                                        intptr_t notification_id) {
    if (connection == FAKE_USB_POWER_CONNECTION)
        return KERN_SUCCESS;
    return IOAllowPowerChange(connection, notification_id);
}

static kern_return_t shim_IOServiceWaitQuiet(
    io_service_t service, mach_timespec_t *wait_time) {
    if (!is_fake_usb_service(service))
        return IOServiceWaitQuiet(service, wait_time);
    // The AVP device has completed enumeration before the bridge publishes
    // it.  MobileDevice's classic restore path waits for the registry service
    // to quiesce before reading properties; there is no kernel registry node
    // behind our userspace handle, so report that already-achieved state.
    usb_shim_log("virtual DFU service is quiet");
    return KERN_SUCCESS;
}

static kern_return_t usb_device_request(
    uint32_t selector, const uint64_t *input, uint32_t input_count,
    uint64_t *output, uint32_t *output_count, void *output_struct,
    size_t *output_struct_count) {
    if (!input || input_count < 8)
        return kIOReturnBadArgument;
    uint16_t length = (uint16_t)input[5];
    bool input_direction = selector == 7;
    void *data = (void *)(uintptr_t)input[6];
    // Ventura IOUSBLib's scalar user-client ABI reports the recovery command
    // buffer's allocation length here on iPadOS, while libusbrestore expects
    // the NUL-terminated command length.  Recover that protocol length from
    // the real caller buffer for iBoot's vendor command request only.
    if (!input_direction && input[1] == 0x40 && input[2] == 0 && data) {
        size_t command_length = strnlen((const char *)data, UINT16_MAX - 1);
        if (command_length < UINT16_MAX && command_length + 1 != length) {
            usb_shim_log("corrected recovery command length %u -> %zu",
                         length, command_length + 1);
            length = (uint16_t)(command_length + 1);
        }
    }
    struct vz_usb_bridge_request request = {
        .operation = VZ_USB_BRIDGE_CONTROL,
        .payload_length = input_direction ? 0 : length,
        .timeout_ms = (uint32_t)(input[7] ? input[7] : 30000),
        .request_type = (uint8_t)input[1],
        .request = (uint8_t)input[2],
        .value = (uint16_t)input[3],
        .index = (uint16_t)input[4],
        .length = length,
    };
    struct vz_usb_bridge_response state = {0};
    usb_bridge_get_state(&state);
    bool restoreos_endpoint_feature =
        state.product_id == 0x12ac &&
        (request.request_type & 0x7fU) == 0x02 &&
        (request.request == 1 || request.request == 3) &&
        request.value == 0;
    if (restoreos_endpoint_feature) {
        // IOUSBLib's ResetPipe sequence toggles ENDPOINT_HALT before asking
        // the interface user client to clear its pipe.  The VMM HCI already
        // owns and resets these endpoint rings; forwarding the standard USB
        // request makes RestoreOS wait for a kernel-host completion that does
        // not exist and eventually reset the whole virtual device.
        usb_shim_log("handled RestoreOS endpoint feature request=0x%02x "
                     "endpoint=0x%02x in userspace", request.request,
                     request.index);
        if (output && output_count && *output_count) {
            output[0] = 0;
            *output_count = 1;
        }
        if (output_struct_count)
            *output_struct_count = 0;
        return KERN_SUCCESS;
    }
    bool recovery_dfu_request = state.product_id == 0x1281 &&
                                (request.request_type & 0x60U) == 0x20U;
    if (recovery_dfu_request && fake_usb_recovery_dfu_recipient_mode == 1)
        request.index = 1;
    else if (recovery_dfu_request &&
             fake_usb_recovery_dfu_recipient_mode == 2) {
        request.request_type &= ~0x1fU;
        request.index = 0;
    }
    usb_shim_log("DeviceRequest raw selector=%u scalars="
                 "%llx,%llx,%llx,%llx,%llx,%llx,%llx,%llx",
                 selector, input[0], input[1], input[2], input[3],
                 input[4], input[5], input[6], input[7]);
    if (!input_direction && data && length && length <= 64)
        usb_shim_log("DeviceRequest OUT bytes=%.*s", (int)length,
                     (const char *)data);
    if (input_direction && output_struct)
        data = output_struct;
    uint32_t capacity = length;
    if (input_direction && output_struct_count &&
        *output_struct_count < capacity)
        capacity = (uint32_t)*output_struct_count;
    struct vz_usb_bridge_response response = {0};
    int result = usb_bridge_request(
        &request, input_direction ? NULL : data,
        input_direction ? data : NULL, capacity, &response);
    if (result && recovery_dfu_request && request.request == 5 &&
        fake_usb_recovery_dfu_recipient_mode == 0) {
        request.index = 1;
        result = usb_bridge_request(
            &request, NULL, data, capacity, &response);
        usb_shim_log("recovery GETSTATE interface-index=1 probe -> %d",
                     result);
        if (!result) {
            fake_usb_recovery_dfu_recipient_mode = 1;
        } else {
            request.request_type &= ~0x1fU;
            request.index = 0;
            result = usb_bridge_request(
                &request, NULL, data, capacity, &response);
            usb_shim_log("recovery GETSTATE device-recipient probe -> %d",
                         result);
            if (!result)
                fake_usb_recovery_dfu_recipient_mode = 2;
        }
    }
    usb_shim_log("DeviceRequest selector=%u type=0x%02llx request=0x%02llx "
                 "value=0x%04llx index=0x%04llx length=%u -> %d actual=%u",
                 selector, input[1], input[2], input[3], input[4], length,
                 result, response.payload_length);
    if (result)
        return kIOReturnNotResponding;
    if (input_direction)
        usb_shim_log_descriptor((uint16_t)input[3], data,
                                response.payload_length);
    if (output && output_count && *output_count) {
        // IOUSBLib treats this scalar as a transport error flag and obtains
        // wLenDone from outputStructCnt.  A byte count here makes it add
        // kIOUSBTransactionTimeout to an otherwise successful IOReturn.
        output[0] = 0;
        *output_count = 1;
    }
    if (output_struct_count)
        *output_struct_count = response.payload_length;
    return KERN_SUCCESS;
}

static kern_return_t shim_IOConnectCallMethod(
    mach_port_t connection, uint32_t selector, const uint64_t *input,
    uint32_t input_count, const void *input_struct,
    size_t input_struct_count, uint64_t *output, uint32_t *output_count,
    void *output_struct, size_t *output_struct_count) {
    if (!is_fake_usb_device_connection(connection) &&
        connection != FAKE_USB_INTERFACE_CONNECTION)
        return IOConnectCallMethod(
            connection, selector, input, input_count, input_struct,
            input_struct_count, output, output_count, output_struct,
            output_struct_count);
    if (is_fake_usb_device_connection(connection) &&
        !fake_usb_connection_is_current(connection))
        return kIOReturnNoDevice;
    if (is_fake_usb_device_connection(connection) &&
        (selector == 6 || selector == 7))
        return usb_device_request(selector, input, input_count, output,
                                  output_count, output_struct,
                                  output_struct_count);
    if (connection == FAKE_USB_INTERFACE_CONNECTION &&
        (selector == 0xb || selector == 0xc))
        return usb_device_request(selector == 0xc ? 7 : 6,
                                  input, input_count, output, output_count,
                                  output_struct, output_struct_count);
    if (connection == FAKE_USB_INTERFACE_CONNECTION &&
        (selector == 6 || selector == 7) && input && input_count >= 7) {
        uint8_t endpoint = 0;
        if (!usb_bridge_endpoint_for_pipe((uint8_t)input[0], &endpoint)) {
            usb_shim_log("pipe %llu has no endpoint", input[0]);
            return kIOReturnBadArgument;
        }
        bool input_direction = selector == 6;
        if (input_direction != ((endpoint & 0x80U) != 0)) {
            usb_shim_log("pipe %llu endpoint=0x%02x has wrong direction for "
                         "selector=%u", input[0], endpoint, selector);
            return kIOReturnBadArgument;
        }
        void *buffer = NULL;
        uint32_t length = 0;
        if (input_direction) {
            if (!output_struct || !output_struct_count ||
                *output_struct_count > UINT32_MAX)
                return kIOReturnBadArgument;
            buffer = output_struct;
            length = (uint32_t)*output_struct_count;
        } else {
            uint64_t requested = input[5];
            if (requested > UINT32_MAX || input_struct_count < requested)
                return kIOReturnBadArgument;
            buffer = (void *)(input_struct ?: (const void *)(uintptr_t)input[4]);
            length = (uint32_t)requested;
        }
        uint64_t timeout = input[2] > input[3] ? input[2] : input[3];
        if (timeout > UINT32_MAX)
            timeout = UINT32_MAX;
        uint32_t actual = 0;
        int result = usb_bridge_bulk_transfer(
            endpoint, buffer, length, (uint32_t)timeout, &actual);
        if (result)
            return kIOReturnNotResponding;
        if (input_direction)
            *output_struct_count = actual;
        return KERN_SUCCESS;
    }
    bool interface_configuration_descriptor =
        connection == FAKE_USB_INTERFACE_CONNECTION && selector == 24;
    bool wants_configuration_descriptor =
        (is_fake_usb_device_connection(connection) && selector == 4) ||
        interface_configuration_descriptor;
    if (wants_configuration_descriptor && input && input_count >= 1 &&
        output_struct && output_struct_count) {
        size_t requested = *output_struct_count;
        if (requested > UINT16_MAX)
            requested = UINT16_MAX;
        uint32_t actual = interface_configuration_descriptor
            ? usb_bridge_read_interface_configuration(
                  output_struct, (uint32_t)requested)
            : usb_bridge_read_descriptor(
                  0x0200, 0, output_struct, (uint32_t)requested);
        int result = actual ? 0 : EIO;
        if (!result)
            *output_struct_count = actual;
        usb_shim_log("%s configuration descriptor index=%llu length=%zu -> "
                     "%d actual=%u",
                     connection == FAKE_USB_INTERFACE_CONNECTION
                         ? "interface" : "device",
                     input[0], requested, result, actual);
        return result ? kIOReturnNotResponding : KERN_SUCCESS;
    }
    usb_shim_log("unimplemented IOConnectCallMethod selector=%u inputs=%u",
                 selector, input_count);
    return kIOReturnUnsupported;
}

static kern_return_t shim_IOConnectCallScalarMethod(
    mach_port_t connection, uint32_t selector, const uint64_t *input,
    uint32_t input_count, uint64_t *output, uint32_t *output_count) {
    if (!is_fake_usb_device_connection(connection) &&
        connection != FAKE_USB_INTERFACE_CONNECTION)
        return IOConnectCallScalarMethod(connection, selector, input,
                                         input_count, output, output_count);
    usb_shim_log("IOConnectCallScalarMethod connection=0x%x selector=%u "
                 "inputs=%u", connection, selector, input_count);
    if (input && input_count) {
        usb_shim_log("scalar inputs=%llx,%llx,%llx,%llx",
                     input_count > 0 ? input[0] : 0,
                     input_count > 1 ? input[1] : 0,
                     input_count > 2 ? input[2] : 0,
                     input_count > 3 ? input[3] : 0);
    }
    if (is_fake_usb_device_connection(connection) &&
        !fake_usb_connection_is_current(connection))
        return kIOReturnNoDevice;
    if (is_fake_usb_device_connection(connection) && selector == 12) {
        struct vz_usb_bridge_request request = {
            .operation = VZ_USB_BRIDGE_RESET,
            .timeout_ms = 30000,
        };
        struct vz_usb_bridge_response response = {0};
        int result = usb_bridge_request(&request, NULL, NULL, 0, &response);
        usb_shim_log("re-enumerated real VM restore device flags=0x%llx "
                     "-> %d generation=%u", input_count ? input[0] : 0,
                     result, response.device_generation);
        return result ? kIOReturnNotResponding : KERN_SUCCESS;
    }
    if (is_fake_usb_device_connection(connection) && selector == 2 && input &&
        input_count >= 1) {
        int result = usb_bridge_set_configuration((uint8_t)input[0]);
        usb_shim_log("set real USB configuration=%llu options=0x%llx "
                     "-> %d", input[0], input_count > 1 ? input[1] : 0,
                     result);
        return result ? kIOReturnNotResponding : KERN_SUCCESS;
    }
    if (is_fake_usb_device_connection(connection) && selector == 8 && output &&
        output_count && *output_count) {
        uint8_t configuration[4096] = {0};
        uint32_t configuration_length = usb_bridge_read_descriptor(
            0x0200, 0, configuration, sizeof(configuration));
        struct vz_usb_bridge_response state = {0};
        usb_bridge_get_state(&state);
        bool found = false;
        uint8_t selected_number = 0;
        uint8_t selected_alternate = 0;
        for (uint32_t offset = 0; offset + 2 <= configuration_length;) {
            uint8_t descriptor_length = configuration[offset];
            if (descriptor_length < 2 ||
                offset + descriptor_length > configuration_length)
                break;
            if (configuration[offset + 1] == 4 &&
                descriptor_length >= 9) {
                uint8_t number = configuration[offset + 2];
                uint8_t alternate = configuration[offset + 3];
                uint8_t interface_class = configuration[offset + 5];
                uint8_t subclass = configuration[offset + 6];
                uint8_t protocol = configuration[offset + 7];
                bool matches = input && input_count >= 4 &&
                    (input[0] == UINT16_MAX || input[0] == interface_class) &&
                    (input[1] == UINT16_MAX || input[1] == subclass) &&
                    (input[2] == UINT16_MAX || input[2] == protocol) &&
                    (input[3] == UINT16_MAX || input[3] == alternate);
                if (matches && !found) {
                    found = true;
                    selected_number = number;
                    selected_alternate = alternate;
                    break;
                }
            }
            offset += descriptor_length;
        }
        fake_usb_interface_iterator_ready = found;
        if (found) {
            fake_usb_selected_interface_number = selected_number;
            fake_usb_selected_interface_alternate = selected_alternate;
        }
        usb_shim_log("interface match product=0x%04x found=%d number=%u "
                     "alternate=%u", state.product_id, found,
                     selected_number, selected_alternate);
        output[0] = FAKE_USB_INTERFACE_ITERATOR;
        *output_count = 1;
        return KERN_SUCCESS;
    }
    if (connection == FAKE_USB_INTERFACE_CONNECTION && selector == 2 &&
        output && output_count && *output_count) {
        struct vz_usb_bridge_response state = {0};
        if (!usb_bridge_get_state(&state) || !state.ready)
            return kIOReturnNotResponding;
        output[0] = fake_usb_device_service(state.device_generation);
        *output_count = 1;
        return KERN_SUCCESS;
    }
    if (connection == FAKE_USB_INTERFACE_CONNECTION && selector == 3 &&
        input && input_count >= 1) {
        struct vz_usb_bridge_request request = {
            .operation = VZ_USB_BRIDGE_CONTROL,
            .timeout_ms = 30000,
            .request_type = 0x01,
            .request = 0x0b,
            .value = (uint16_t)input[0],
            .index = fake_usb_selected_interface_number,
        };
        struct vz_usb_bridge_response response = {0};
        int result = usb_bridge_request(
            &request, NULL, NULL, 0, &response);
        if (!result)
            fake_usb_selected_interface_alternate = (uint8_t)input[0];
        if (!result)
            result = usb_bridge_create_active_endpoints();
        usb_shim_log("set real interface=%u alternate=%llu -> %d",
                     fake_usb_selected_interface_number, input[0], result);
        return result ? kIOReturnNotResponding : KERN_SUCCESS;
    }
    if (connection == FAKE_USB_INTERFACE_CONNECTION && selector == 5 &&
        input && input_count >= 1 && output && output_count &&
        *output_count >= 5) {
        uint8_t configuration[4096] = {0};
        uint32_t configuration_length = usb_bridge_read_descriptor(
            0x0200, 0, configuration, sizeof(configuration));
        uint8_t wanted_pipe = (uint8_t)input[0];
        uint8_t pipe = 0;
        bool selected = false;
        for (uint32_t offset = 0; offset + 2 <= configuration_length;) {
            uint8_t descriptor_length = configuration[offset];
            if (descriptor_length < 2 ||
                offset + descriptor_length > configuration_length)
                break;
            if (configuration[offset + 1] == 4 &&
                descriptor_length >= 9) {
                selected = configuration[offset + 2] ==
                               fake_usb_selected_interface_number &&
                           configuration[offset + 3] ==
                               fake_usb_selected_interface_alternate;
                pipe = 0;
            } else if (selected && configuration[offset + 1] == 5 &&
                       descriptor_length >= 7) {
                pipe++;
                if (pipe == wanted_pipe) {
                    uint8_t endpoint = configuration[offset + 2];
                    fake_usb_pipe_endpoints[wanted_pipe] = endpoint;
                    output[0] = (endpoint & 0x80U) ? 1 : 0;
                    output[1] = endpoint & 0x0fU;
                    output[2] = configuration[offset + 3] & 0x03U;
                    output[3] = (uint16_t)configuration[offset + 4] |
                                ((uint16_t)configuration[offset + 5] << 8);
                    output[4] = configuration[offset + 6];
                    *output_count = 5;
                    usb_shim_log("pipe %u endpoint=0x%02x type=%llu "
                                 "max-packet=%llu", wanted_pipe, endpoint,
                                 output[2], output[3]);
                    return KERN_SUCCESS;
                }
            }
            offset += descriptor_length;
        }
        return kIOReturnNotFound;
    }
    if (connection == FAKE_USB_INTERFACE_CONNECTION && selector == 14 &&
        input && input_count >= 3 && output && output_count &&
        *output_count >= 3) {
        uint8_t configuration[4096] = {0};
        uint32_t configuration_length = usb_bridge_read_descriptor(
            0x0200, 0, configuration, sizeof(configuration));
        uint8_t wanted_alternate = (uint8_t)input[0];
        uint8_t wanted_number = (uint8_t)input[1] & 0x0fU;
        bool wanted_input = input[2] != 0;
        bool selected = false;
        for (uint32_t offset = 0; offset + 2 <= configuration_length;) {
            uint8_t descriptor_length = configuration[offset];
            if (descriptor_length < 2 ||
                offset + descriptor_length > configuration_length)
                break;
            if (configuration[offset + 1] == 4 &&
                descriptor_length >= 9) {
                selected = configuration[offset + 2] ==
                               fake_usb_selected_interface_number &&
                           configuration[offset + 3] ==
                               wanted_alternate;
            } else if (selected && configuration[offset + 1] == 5 &&
                       descriptor_length >= 7) {
                uint8_t endpoint = configuration[offset + 2];
                if ((endpoint & 0x0fU) == wanted_number &&
                    ((endpoint & 0x80U) != 0) == wanted_input) {
                    output[0] = configuration[offset + 3] & 0x03U;
                    output[1] = (uint16_t)configuration[offset + 4] |
                                ((uint16_t)configuration[offset + 5] << 8);
                    output[2] = configuration[offset + 6];
                    *output_count = 3;
                    usb_shim_log("endpoint properties alternate=%u "
                                 "number=%u direction=%s type=%llu "
                                 "max-packet=%llu interval=%llu",
                                 wanted_alternate, wanted_number,
                                 wanted_input ? "in" : "out", output[0],
                                 output[1], output[2]);
                    return KERN_SUCCESS;
                }
            }
            offset += descriptor_length;
        }
        return kIOReturnNotFound;
    }
    if (connection == FAKE_USB_INTERFACE_CONNECTION &&
        (selector == 8 || selector == 9 || selector == 10 ||
         selector == 13)) {
        // GetPipeStatus, AbortPipe, ClearPipeStall, and SetPipePolicy are
        // bookkeeping operations for the kernel user client.  The bridge
        // performs transfers synchronously and VMM owns endpoint-ring state,
        // so there is no additional kernel-side operation to perform here.
        return KERN_SUCCESS;
    }
    if (selector <= 5)
        return KERN_SUCCESS;
    return kIOReturnUnsupported;
}

static kern_return_t shim_IOConnectCallAsyncScalarMethod(
    mach_port_t connection, uint32_t selector, mach_port_t wake_port,
    uint64_t *reference, uint32_t reference_count, const uint64_t *input,
    uint32_t input_count, uint64_t *output, uint32_t *output_count) {
    if (connection != FAKE_USB_INTERFACE_CONNECTION)
        return IOConnectCallAsyncScalarMethod(
            connection, selector, wake_port, reference, reference_count,
            input, input_count, output, output_count);
    usb_shim_log("IOConnectCallAsyncScalarMethod selector=%u wake=0x%x "
                 "references=%u inputs=%u", selector, wake_port,
                 reference_count, input_count);
    // IOUSBLib selector 19 registers the notification port used for its
    // kernel-delivered completions.  Completions for the userspace bridge are
    // dispatched directly below, but IOUSBLib still requires this setup call
    // to succeed before it will submit asynchronous pipe transfers.
    return selector == 19 ? KERN_SUCCESS : kIOReturnUnsupported;
}

static kern_return_t shim_IOConnectCallAsyncMethod(
    mach_port_t connection, uint32_t selector, mach_port_t wake_port,
    uint64_t *reference, uint32_t reference_count, const uint64_t *input,
    uint32_t input_count, const void *input_struct, size_t input_struct_count,
    uint64_t *output, uint32_t *output_count, void *output_struct,
    size_t *output_struct_count) {
    if (connection != FAKE_USB_INTERFACE_CONNECTION)
        return IOConnectCallAsyncMethod(
            connection, selector, wake_port, reference, reference_count,
            input, input_count, input_struct, input_struct_count, output,
            output_count, output_struct, output_struct_count);
    if (usb_shim_trace_transfers())
        usb_shim_log("IOConnectCallAsyncMethod selector=%u wake=0x%x "
                     "references=%u inputs=%u", selector, wake_port,
                     reference_count, input_count);
    if ((selector != 6 && selector != 7) || !reference ||
        reference_count < 3 || !input || input_count < 7)
        return kIOReturnUnsupported;
    uint8_t endpoint = 0;
    if (!usb_bridge_endpoint_for_pipe((uint8_t)input[0], &endpoint))
        return kIOReturnBadArgument;
    bool input_direction = selector == 6;
    if (input_direction != ((endpoint & 0x80U) != 0))
        return kIOReturnBadArgument;
    if (input[5] > UINT32_MAX)
        return kIOReturnBadArgument;
    void *buffer = (void *)(uintptr_t)input[4];
    uint32_t length = (uint32_t)input[5];
    uint64_t timeout_value = input[2] > input[3] ? input[2] : input[3];
    uint32_t timeout = timeout_value > UINT32_MAX
                           ? UINT32_MAX
                           : (uint32_t)timeout_value;
    if (input_direction && timeout == 0)
        timeout = UINT32_MAX;
    IOAsyncCallback1 callback = (IOAsyncCallback1)(uintptr_t)reference[1];
    void *refcon = (void *)(uintptr_t)reference[2];
    if (!callback || (!buffer && length))
        return kIOReturnBadArgument;
    if (usb_shim_trace_transfers())
        usb_shim_log("queued async bulk pipe=%llu endpoint=0x%02x length=%u "
                     "timeout=%u callback=%p refcon=%p", input[0], endpoint,
                     length, timeout, callback, refcon);
    dispatch_queue_t transfer_queue = input_direction
        ? fake_usb_bulk_input_queue : fake_usb_bulk_output_queue;
    dispatch_async(transfer_queue, ^{
        uint32_t actual = 0;
        int result = usb_bridge_bulk_transfer(endpoint, buffer, length,
                                              timeout, &actual);
        IOReturn completion_result =
            result ? kIOReturnNotResponding : KERN_SUCCESS;
        if (result || usb_shim_trace_transfers())
            usb_shim_log("completing async bulk endpoint=0x%02x result=0x%x "
                         "actual=%u", endpoint, completion_result, actual);
        // Native IOUSBLib posts this completion to the notification port
        // whose run-loop source usbmuxd installed on its main run loop.
        // Preserve that threading contract; its mux-interface state is not
        // designed to be mutated from bridge worker queues.
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(refcon, completion_result,
                     (void *)(uintptr_t)actual);
        });
    });
    return KERN_SUCCESS;
}

static kern_return_t shim_IOCreatePlugInInterfaceForService(
    io_service_t service, CFUUIDRef plugin_type, CFUUIDRef interface_type,
    IOCFPlugInInterface ***interface, SInt32 *score) {
    if (!is_fake_usb_service(service)) {
        static kern_return_t (*original)(io_service_t, CFUUIDRef, CFUUIDRef,
                                         IOCFPlugInInterface ***, SInt32 *);
        if (!original)
            original = dlsym(RTLD_NEXT,
                             "IOCreatePlugInInterfaceForService");
        return original ? original(service, plugin_type, interface_type,
                                   interface, score)
                        : kIOReturnUnsupported;
    }
    static void *library;
    static void *(*factory)(CFAllocatorRef, CFUUIDRef);
    if (!library) {
        library = dlopen(
            "/System/Library/Extensions/IOUSBHostFamily.kext/PlugIns/"
            "IOUSBLib.bundle/IOUSBLib", RTLD_NOW | RTLD_GLOBAL);
        if (library)
            factory = dlsym(library, "IOUSBLibFactory");
        usb_shim_log("loaded native IOUSBLib=%p factory=%p error=%s",
                     library, factory, library ? "none" : dlerror());
    }
    if (!factory)
        return kIOReturnUnsupported;
    IOCFPlugInInterface **plugin = factory(kCFAllocatorDefault, plugin_type);
    if (!plugin || !*plugin)
        return kIOReturnNoMemory;
    SInt32 local_score = 0;
    IOReturn result = (*plugin)->Probe(
        plugin, NULL, service, score ? score : &local_score);
    if (result == KERN_SUCCESS)
        result = (*plugin)->Start(plugin, NULL, service);
    usb_shim_log("native IOUSBLib plugin=%p probe/start -> 0x%x",
                 plugin, result);
    if (result != KERN_SUCCESS) {
        (*plugin)->Release(plugin);
        return result;
    }
    *interface = plugin;
    return KERN_SUCCESS;
}

#define INTERPOSE(name, replacement, original) \
    __attribute__((used)) static struct { \
        const void *replacement; const void *original; \
    } name __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)&replacement, (const void *)&original \
    }

INTERPOSE(ip_usb_add_matching, shim_IOServiceAddMatchingNotification,
          IOServiceAddMatchingNotification);
INTERPOSE(ip_usb_get_matching, shim_IOServiceGetMatchingServices,
          IOServiceGetMatchingServices);
INTERPOSE(ip_usb_notification_queue,
          shim_IONotificationPortSetDispatchQueue,
          IONotificationPortSetDispatchQueue);
INTERPOSE(ip_usb_iterator_next, shim_IOIteratorNext, IOIteratorNext);
INTERPOSE(ip_usb_object_retain, shim_IOObjectRetain, IOObjectRetain);
INTERPOSE(ip_usb_object_release, shim_IOObjectRelease, IOObjectRelease);
INTERPOSE(ip_usb_object_conforms, shim_IOObjectConformsTo,
          IOObjectConformsTo);
INTERPOSE(ip_usb_properties, shim_IORegistryEntryCreateCFProperties,
          IORegistryEntryCreateCFProperties);
INTERPOSE(ip_usb_property, shim_IORegistryEntryCreateCFProperty,
          IORegistryEntryCreateCFProperty);
INTERPOSE(ip_usb_name, shim_IORegistryEntryGetName,
          IORegistryEntryGetName);
INTERPOSE(ip_usb_name_plane, shim_IORegistryEntryGetNameInPlane,
          IORegistryEntryGetNameInPlane);
INTERPOSE(ip_usb_entry_id, shim_IORegistryEntryGetRegistryEntryID,
          IORegistryEntryGetRegistryEntryID);
INTERPOSE(ip_usb_parent, shim_IORegistryEntryGetParentEntry,
          IORegistryEntryGetParentEntry);
INTERPOSE(ip_usb_interest, shim_IOServiceAddInterestNotification,
          IOServiceAddInterestNotification);
INTERPOSE(ip_usb_service_open, shim_IOServiceOpen, IOServiceOpen);
INTERPOSE(ip_usb_service_close, shim_IOServiceClose, IOServiceClose);
INTERPOSE(ip_usb_service_wait_quiet, shim_IOServiceWaitQuiet,
          IOServiceWaitQuiet);
INTERPOSE(ip_usb_connect_method, shim_IOConnectCallMethod,
          IOConnectCallMethod);
INTERPOSE(ip_usb_connect_scalar, shim_IOConnectCallScalarMethod,
          IOConnectCallScalarMethod);
INTERPOSE(ip_usb_connect_async_scalar,
          shim_IOConnectCallAsyncScalarMethod,
          IOConnectCallAsyncScalarMethod);
INTERPOSE(ip_usb_connect_async, shim_IOConnectCallAsyncMethod,
          IOConnectCallAsyncMethod);
INTERPOSE(ip_usb_create_plugin, shim_IOCreatePlugInInterfaceForService,
          IOCreatePlugInInterfaceForService);
INTERPOSE(ip_usb_system_power, shim_IORegisterForSystemPower,
          IORegisterForSystemPower);
INTERPOSE(ip_usb_allow_power, shim_IOAllowPowerChange,
          IOAllowPowerChange);

__attribute__((constructor)) static void installation_usb_shim_init(void) {
    fake_usb_notification_queue = dispatch_queue_create(
        "org.jb.virtualization.installation-usb", DISPATCH_QUEUE_CONCURRENT);
    // IOUSBLib submits multiple reads and writes ahead of time, but each USB
    // endpoint is an ordered stream.  Preserve submission order before the
    // requests cross the userspace bridge; a concurrent worker queue can
    // otherwise associate later USBMux sequence packets with earlier read
    // callbacks and make usbmuxd report duplicate/skipped packets.
    fake_usb_bulk_input_queue = dispatch_queue_create(
        "org.jb.virtualization.installation-usb.bulk-in",
        DISPATCH_QUEUE_SERIAL);
    fake_usb_bulk_output_queue = dispatch_queue_create(
        "org.jb.virtualization.installation-usb.bulk-out",
        DISPATCH_QUEUE_SERIAL);
    usb_shim_log("loaded; native IOUSBLib bridge enabled");
}
