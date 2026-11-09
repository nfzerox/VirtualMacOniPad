#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hidsystem/IOHIDUserDevice.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/vsock.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum {
    kGamepadReportLength = 16,
    kGamepadButtonCount = 16,
    kGamepadPacketLength = 32,
    kGamepadProtocolVersion = 1,
    kGamepadPacketTypeState = 1,
    kGamepadPacketTypeAck = 2,
    kGamepadAckLength = 16,
    kGamepadDefaultStateTimeoutMilliseconds = 750,
    // Full-state packets make a large backlog harmful: replaying seconds of old
    // input is worse than dropping it. The sender repeats edges and keepalives.
    kGamepadReceiveBufferBytes = 8 * 1024,
    kGamepadMaxBatchPackets = 1024,
    // Remember a few recently replaced sender/session pairs so a delayed UDP
    // packet cannot immediately reclaim the virtual controller after a newer
    // app instance or network path has taken over.
    kGamepadRetiredStreamCapacity = 4,
    kGamepadRetiredStreamLifetimeMilliseconds = 3000,
    kGamepadDefaultPort = 25863,
    kGamepadStreamBufferBytes = 32 * 64,
    kGamepadAckQueueBytes = 16 * 16,
};

typedef enum {
    GamepadTransportSynthetic,
    GamepadTransportUDP,
    GamepadTransportVsock,
} GamepadTransport;

static volatile sig_atomic_t gStop;

static void handle_signal(int signal_number) {
    (void)signal_number;
    gStop = 1;
}

static CFNumberRef number_for_int(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static const uint8_t kGenericGamepadDescriptor[] = {
    0x05, 0x01,       // Usage Page (Generic Desktop)
    0x09, 0x05,       // Usage (Game Pad)
    0xA1, 0x01,       // Collection (Application)
    0x85, 0x01,       //   Report ID (1)
    0x05, 0x09,       //   Usage Page (Button)
    0x19, 0x01,       //   Usage Minimum (Button 1)
    0x29, 0x10,       //   Usage Maximum (Button 16)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x01,       //   Logical Maximum (1)
    0x95, 0x10,       //   Report Count (16)
    0x75, 0x01,       //   Report Size (1)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x05, 0x01,       //   Usage Page (Generic Desktop)
    0x09, 0x30,       //   Usage (X)
    0x09, 0x31,       //   Usage (Y)
    0x09, 0x33,       //   Usage (Rx)
    0x09, 0x34,       //   Usage (Ry)
    0x16, 0x00, 0x80, //   Logical Minimum (-32768)
    0x26, 0xFF, 0x7F, //   Logical Maximum (32767)
    0x75, 0x10,       //   Report Size (16)
    0x95, 0x04,       //   Report Count (4)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x09, 0x32,       //   Usage (Z)
    0x09, 0x35,       //   Usage (Rz)
    0x15, 0x00,       //   Logical Minimum (0)
    // A 16-bit HID Logical Maximum is signed because Logical Minimum is zero.
    // Use the 32-bit item form so 65535 is not decoded as -1 by IOHIDFamily.
    0x27, 0xFF, 0xFF, 0x00, 0x00, // Logical Maximum (65535)
    0x75, 0x10,       //   Report Size (16)
    0x95, 0x02,       //   Report Count (2)
    0x81, 0x02,       //   Input (Data, Variable, Absolute)
    0x09, 0x39,       //   Usage (Hat switch)
    0x15, 0x00,       //   Logical Minimum (0)
    0x25, 0x07,       //   Logical Maximum (7)
    0x35, 0x00,       //   Physical Minimum (0)
    0x46, 0x3B, 0x01, //   Physical Maximum (315)
    0x65, 0x14,       //   Unit (English Rotation)
    0x75, 0x04,       //   Report Size (4)
    0x95, 0x01,       //   Report Count (1)
    0x81, 0x42,       //   Input (Data, Variable, Absolute, Null State)
    0x75, 0x04,       //   Report Size (4)
    0x95, 0x01,       //   Report Count (1)
    0x81, 0x03,       //   Input (Constant, Variable, Absolute)
    0xC0,             // End Collection
};

static void neutral_report(uint8_t report[kGamepadReportLength]) {
    memset(report, 0, kGamepadReportLength);
    report[0] = 0x01;
    report[15] = 0x08;
}

typedef struct {
    pthread_mutex_t lock;
    uint8_t report[kGamepadReportLength];
} GamepadReportState;

static void store_current_report(
    GamepadReportState *state,
    const uint8_t report[kGamepadReportLength]) {
    pthread_mutex_lock(&state->lock);
    memcpy(state->report, report, kGamepadReportLength);
    pthread_mutex_unlock(&state->lock);
}

static void load_current_report(
    GamepadReportState *state,
    uint8_t report[kGamepadReportLength]) {
    pthread_mutex_lock(&state->lock);
    memcpy(report, state->report, kGamepadReportLength);
    pthread_mutex_unlock(&state->lock);
}

static const char *dpad_name_for_generic(uint8_t hat) {
    static const char *names[] = {
        "up", "up-right", "right", "down-right",
        "down", "down-left", "left", "up-left", "neutral",
    };
    return hat <= 8 ? names[hat] : "invalid";
}

static IOReturn handle_gamepad_report(
    IOHIDUserDeviceRef device, GamepadReportState *state, uint64_t timestamp,
    const uint8_t report[kGamepadReportLength]) {
    IOReturn status = IOHIDUserDeviceHandleReportWithTimeStamp(
        device, timestamp, report, kGamepadReportLength);
    if (status == kIOReturnSuccess) {
        store_current_report(state, report);
    }
    return status;
}

static void make_report(uint8_t report[kGamepadReportLength], double seconds) {
    neutral_report(report);

    if (seconds >= 1.0 && seconds < 2.0) {
        report[1] = 0x01; // Button 1.
    }

    double phase = seconds * 2.0 * 3.14159265358979323846;
    int16_t x = (int16_t)lrint(sin(phase) * 28000.0);
    int16_t y = (int16_t)lrint(cos(phase) * 28000.0);
    int16_t rx = (int16_t)lrint(sin(phase * 0.5) * 22000.0);
    int16_t ry = (int16_t)lrint(cos(phase * 0.5) * 22000.0);
    uint16_t z = (uint16_t)lrint((sin(seconds * 3.0) * 0.5 + 0.5) * 65535.0);
    uint16_t rz = (uint16_t)lrint((cos(seconds * 2.0) * 0.5 + 0.5) * 65535.0);

    memcpy(&report[3], &x, sizeof(x));
    memcpy(&report[5], &y, sizeof(y));
    memcpy(&report[7], &rx, sizeof(rx));
    memcpy(&report[9], &ry, sizeof(ry));
    memcpy(&report[11], &z, sizeof(z));
    memcpy(&report[13], &rz, sizeof(rz));
    report[15] = (uint8_t)((int)(seconds * 2.0) % 9);
}

static uint64_t monotonic_timestamp(void) {
    return mach_absolute_time();
}

static double seconds_between(uint64_t later, uint64_t earlier) {
    static dispatch_once_t once;
    static double seconds_per_tick;
    dispatch_once(&once, ^{
        mach_timebase_info_data_t timebase_info;
        mach_timebase_info(&timebase_info);
        seconds_per_tick = (double)timebase_info.numer /
                           (double)timebase_info.denom / 1e9;
    });
    return (double)(later - earlier) * seconds_per_tick;
}

static uint16_t read_be16(const uint8_t *value) {
    return (uint16_t)((uint16_t)value[0] << 8 | value[1]);
}

static uint32_t read_be32(const uint8_t *value) {
    return (uint32_t)((uint32_t)value[0] << 24 | (uint32_t)value[1] << 16 |
                      (uint32_t)value[2] << 8 | value[3]);
}

static bool packet_is_newer(uint32_t candidate, uint32_t previous) {
    return (int32_t)(candidate - previous) > 0;
}

static bool decode_state_packet(const uint8_t packet[kGamepadPacketLength],
                                uint32_t *sequence,
                                uint32_t *session,
                                uint8_t report[kGamepadReportLength]) {
    if (read_be32(&packet[0]) != 0x564D4750 || // "VMGP"
        packet[4] != kGamepadProtocolVersion ||
        packet[5] != kGamepadPacketTypeState ||
        read_be16(&packet[6]) != kGamepadReportLength ||
        packet[16] != 0x01 || packet[31] > 8) {
        return false;
    }
    *sequence = read_be32(&packet[8]);
    *session = read_be32(&packet[12]);
    memcpy(report, &packet[16], kGamepadReportLength);
    return true;
}

static int create_udp_listener(uint16_t port) {
    int socket_fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (socket_fd < 0) {
        perror("[gamepad-probe] socket");
        return -1;
    }
    int receive_buffer = kGamepadReceiveBufferBytes;
    (void)setsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF, &receive_buffer,
                     sizeof(receive_buffer));
    int flags = fcntl(socket_fd, F_GETFL, 0);
    if (flags < 0 || fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) != 0) {
        fprintf(stderr, "[gamepad-probe] failed to make UDP socket nonblocking: %s\n",
                strerror(errno));
        close(socket_fd);
        return -1;
    }
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(socket_fd, (const struct sockaddr *)&address, sizeof(address)) != 0) {
        fprintf(stderr, "[gamepad-probe] bind UDP %u failed: %s\n",
                (unsigned)port,
                strerror(errno));
        close(socket_fd);
        return -1;
    }
    return socket_fd;
}

static bool make_nonblocking(int socket_fd) {
    int flags = fcntl(socket_fd, F_GETFL, 0);
    return flags >= 0 &&
           fcntl(socket_fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static int create_vsock_listener(uint32_t port) {
    int socket_fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (socket_fd < 0) {
        perror("[gamepad-probe] AF_VSOCK socket");
        return -1;
    }
    if (!make_nonblocking(socket_fd)) {
        fprintf(stderr, "[gamepad-probe] failed to make vsock listener nonblocking: %s\n",
                strerror(errno));
        close(socket_fd);
        return -1;
    }
    struct sockaddr_vm address = {0};
    address.svm_len = sizeof(address);
    address.svm_family = AF_VSOCK;
    address.svm_port = port;
    address.svm_cid = VMADDR_CID_ANY;
    if (bind(socket_fd, (const struct sockaddr *)&address,
             sizeof(address)) != 0 || listen(socket_fd, 1) != 0) {
        fprintf(stderr, "[gamepad-probe] bind/listen vsock %u failed: %s\n",
                (unsigned)port, strerror(errno));
        close(socket_fd);
        return -1;
    }
    return socket_fd;
}

static void make_ack(uint8_t ack[kGamepadAckLength], uint32_t sequence,
                     uint32_t session) {
    memset(ack, 0, kGamepadAckLength);
    ack[0] = 'V'; ack[1] = 'M'; ack[2] = 'G'; ack[3] = 'A';
    ack[4] = kGamepadProtocolVersion;
    ack[5] = kGamepadPacketTypeAck;
    ack[8] = (uint8_t)(sequence >> 24);
    ack[9] = (uint8_t)(sequence >> 16);
    ack[10] = (uint8_t)(sequence >> 8);
    ack[11] = (uint8_t)sequence;
    ack[12] = (uint8_t)(session >> 24);
    ack[13] = (uint8_t)(session >> 16);
    ack[14] = (uint8_t)(session >> 8);
    ack[15] = (uint8_t)session;
}

static bool send_ack(int socket_fd, const struct sockaddr *destination,
                     socklen_t destination_length, uint32_t sequence,
                     uint32_t session) {
    uint8_t ack[kGamepadAckLength];
    make_ack(ack, sequence, session);
    return sendto(socket_fd, ack, sizeof(ack), 0, destination,
                  destination_length) == sizeof(ack);
}

static bool queue_stream_ack(uint8_t buffer[kGamepadAckQueueBytes],
                             size_t *length, uint32_t sequence,
                             uint32_t session) {
    if (*length + kGamepadAckLength > kGamepadAckQueueBytes)
        return false;
    make_ack(&buffer[*length], sequence, session);
    *length += kGamepadAckLength;
    return true;
}

// Returns 1 when all queued bytes were written, 0 when the socket would block,
// and -1 on EOF or a permanent error. Keeping byte offsets (rather than ACK
// objects) makes partial stream writes correct without replaying a prefix.
static int flush_stream_acks(int socket_fd,
                             uint8_t buffer[kGamepadAckQueueBytes],
                             size_t *length) {
    while (*length > 0) {
        ssize_t sent = send(socket_fd, buffer, *length, 0);
        if (sent > 0) {
            memmove(buffer, buffer + sent, *length - (size_t)sent);
            *length -= (size_t)sent;
            continue;
        }
        if (sent < 0 && errno == EINTR)
            continue;
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
            return 0;
        return -1;
    }
    return 1;
}

static bool socket_addresses_equal(const struct sockaddr_storage *left,
                                   const struct sockaddr_storage *right) {
    if (left->ss_family != right->ss_family) {
        return false;
    }
    if (left->ss_family == AF_INET) {
        const struct sockaddr_in *left4 = (const struct sockaddr_in *)left;
        const struct sockaddr_in *right4 = (const struct sockaddr_in *)right;
        return left4->sin_port == right4->sin_port &&
               left4->sin_addr.s_addr == right4->sin_addr.s_addr;
    }
    if (left->ss_family == AF_INET6) {
        const struct sockaddr_in6 *left6 = (const struct sockaddr_in6 *)left;
        const struct sockaddr_in6 *right6 = (const struct sockaddr_in6 *)right;
        return left6->sin6_port == right6->sin6_port &&
               left6->sin6_scope_id == right6->sin6_scope_id &&
               memcmp(&left6->sin6_addr, &right6->sin6_addr,
                      sizeof(left6->sin6_addr)) == 0;
    }
    return false;
}

typedef struct {
    bool valid;
    struct sockaddr_storage sender;
    uint32_t session;
    uint64_t retired_at;
} RetiredGamepadStream;

static bool retired_stream_matches(
    RetiredGamepadStream streams[kGamepadRetiredStreamCapacity],
    const struct sockaddr_storage *sender, uint32_t session, uint64_t now) {
    for (size_t index = 0; index < kGamepadRetiredStreamCapacity; index++) {
        RetiredGamepadStream *stream = &streams[index];
        if (!stream->valid) {
            continue;
        }
        if (seconds_between(now, stream->retired_at) * 1000.0 >=
            kGamepadRetiredStreamLifetimeMilliseconds) {
            stream->valid = false;
            continue;
        }
        if (stream->session == session &&
            socket_addresses_equal(&stream->sender, sender)) {
            return true;
        }
    }
    return false;
}

static void retire_stream(
    RetiredGamepadStream streams[kGamepadRetiredStreamCapacity],
    const struct sockaddr_storage *sender, uint32_t session, uint64_t now) {
    size_t replacement = 0;
    for (size_t index = 0; index < kGamepadRetiredStreamCapacity; index++) {
        if (!streams[index].valid) {
            replacement = index;
            goto selected;
        }
        if (streams[index].retired_at < streams[replacement].retired_at) {
            replacement = index;
        }
    }
selected:
    streams[replacement].valid = true;
    streams[replacement].sender = *sender;
    streams[replacement].session = session;
    streams[replacement].retired_at = now;
}

static bool trigger_is_pressed(
    const uint8_t report[kGamepadReportLength], size_t offset) {
    uint16_t value = 0;
    memcpy(&value, &report[offset], sizeof(value));
    return value >= UINT16_C(32768);
}

static void print_state(uint32_t sequence,
                        const uint8_t report[kGamepadReportLength]) {
    uint16_t buttons = (uint16_t)report[1] | (uint16_t)report[2] << 8;
    int16_t x, y, rx, ry;
    uint16_t z, rz;
    memcpy(&x, &report[3], sizeof(x));
    memcpy(&y, &report[5], sizeof(y));
    memcpy(&rx, &report[7], sizeof(rx));
    memcpy(&ry, &report[9], sizeof(ry));
    memcpy(&z, &report[11], sizeof(z));
    memcpy(&rz, &report[13], sizeof(rz));
    fprintf(stderr, "[gamepad-probe] seq=%u buttons=0x%04x "
            "left=%+.3f,%+.3f right=%+.3f,%+.3f "
            "triggers=%.3f,%.3f hat=%u(%s)\n",
            (unsigned)sequence, (unsigned)buttons,
            (double)x / 32767.0, (double)y / 32767.0,
            (double)rx / 32767.0, (double)ry / 32767.0,
            (double)z / 65535.0, (double)rz / 65535.0,
            (unsigned)report[15],
            dpad_name_for_generic(report[15]));
}

static void make_test_packet(uint8_t packet[kGamepadPacketLength],
                             uint32_t sequence, uint32_t session) {
    memset(packet, 0, kGamepadPacketLength);
    packet[0] = 'V'; packet[1] = 'M'; packet[2] = 'G'; packet[3] = 'P';
    packet[4] = kGamepadProtocolVersion;
    packet[5] = kGamepadPacketTypeState;
    packet[7] = kGamepadReportLength;
    packet[8] = (uint8_t)(sequence >> 24);
    packet[9] = (uint8_t)(sequence >> 16);
    packet[10] = (uint8_t)(sequence >> 8);
    packet[11] = (uint8_t)sequence;
    packet[12] = (uint8_t)(session >> 24);
    packet[13] = (uint8_t)(session >> 16);
    packet[14] = (uint8_t)(session >> 8);
    packet[15] = (uint8_t)session;
    packet[16] = 1;
    packet[31] = 8;
}

static bool run_stream_protocol_tests(void) {
    uint8_t packets[kGamepadPacketLength * 3];
    for (uint32_t index = 0; index < 3; index++)
        make_test_packet(&packets[index * kGamepadPacketLength], index + 1,
                         UINT32_C(0x12345678));
    const size_t fragments[] = {1, 7, 24, 64};
    uint8_t stream[kGamepadStreamBufferBytes];
    size_t stream_length = 0, source_offset = 0, decoded = 0;
    for (size_t fragment = 0; fragment < sizeof(fragments) / sizeof(fragments[0]);
         fragment++) {
        size_t length = fragments[fragment];
        memcpy(stream + stream_length, packets + source_offset, length);
        stream_length += length;
        source_offset += length;
        while (stream_length >= kGamepadPacketLength) {
            uint32_t sequence = 0, session = 0;
            uint8_t report[kGamepadReportLength];
            if (!decode_state_packet(stream, &sequence, &session, report) ||
                sequence != decoded + 1 || session != UINT32_C(0x12345678))
                return false;
            memmove(stream, stream + kGamepadPacketLength,
                    stream_length - kGamepadPacketLength);
            stream_length -= kGamepadPacketLength;
            decoded++;
        }
    }
    if (decoded != 3 || stream_length != 0)
        return false;
    packets[0] = 'X';
    uint32_t sequence = 0, session = 0;
    uint8_t report[kGamepadReportLength];
    if (decode_state_packet(packets, &sequence, &session, report))
        return false;

    int pair[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0)
        return false;
    if (!make_nonblocking(pair[0]) || !make_nonblocking(pair[1])) {
        close(pair[0]); close(pair[1]);
        return false;
    }
    uint8_t filler[1024] = {0};
    while (send(pair[0], filler, sizeof(filler), 0) > 0) {}
    uint8_t ack_queue[kGamepadAckQueueBytes];
    size_t ack_length = 0;
    bool result = queue_stream_ack(ack_queue, &ack_length, 9,
                                   UINT32_C(0x12345678)) &&
                  flush_stream_acks(pair[0], ack_queue, &ack_length) == 0 &&
                  ack_length == kGamepadAckLength;
    while (recv(pair[1], filler, sizeof(filler), 0) > 0) {}
    result = result &&
        flush_stream_acks(pair[0], ack_queue, &ack_length) == 1 &&
        ack_length == 0;
    close(pair[0]); close(pair[1]);
    return result;
}

static void print_usage(const char *program) {
    fprintf(stderr, "usage: %s [--duration SECONDS] "
            "[--transport vsock|udp --port PORT] [--listen UDP_PORT] "
            "[--timeout-ms MILLISECONDS] [--stats] "
            "[--print-state] [--self-test-stream]\n", program);
}

int main(int argc, char **argv) {
    double duration = 8.0;
    bool duration_was_set = false;
    uint16_t listen_port = 0;
    GamepadTransport transport = GamepadTransportSynthetic;
    bool print_received_state = false;
    bool print_stats = false;
    uint32_t state_timeout_ms = kGamepadDefaultStateTimeoutMilliseconds;
    bool self_test_stream = false;
    int exit_status = 0;
    for (int argument = 1; argument < argc;) {
        if (strcmp(argv[argument], "--print-state") == 0) {
            print_received_state = true;
            argument++;
            continue;
        }
        if (strcmp(argv[argument], "--stats") == 0) {
            print_stats = true;
            argument++;
            continue;
        }
        if (strcmp(argv[argument], "--self-test-stream") == 0) {
            self_test_stream = true;
            argument++;
            continue;
        }
        if (argument + 1 >= argc) {
            print_usage(argv[0]);
            return 2;
        }
        if (strcmp(argv[argument], "--duration") == 0) {
            char *end = NULL;
            errno = 0;
            duration = strtod(argv[argument + 1], &end);
            if (errno == ERANGE || !end || *end != '\0' ||
                !(duration > 0.0) || !isfinite(duration)) {
                fprintf(stderr, "duration must be greater than zero\n");
                return 2;
            }
            duration_was_set = true;
        } else if (strcmp(argv[argument], "--transport") == 0) {
            if (strcmp(argv[argument + 1], "vsock") == 0)
                transport = GamepadTransportVsock;
            else if (strcmp(argv[argument + 1], "udp") == 0)
                transport = GamepadTransportUDP;
            else {
                fprintf(stderr, "transport must be vsock or udp\n");
                return 2;
            }
            if (!listen_port)
                listen_port = kGamepadDefaultPort;
            if (!duration_was_set)
                duration = 0.0;
        } else if (strcmp(argv[argument], "--port") == 0 ||
                   strcmp(argv[argument], "--listen") == 0) {
            char *end = NULL;
            long parsed = strtol(argv[argument + 1], &end, 10);
            if (!end || *end != '\0' || parsed < 1 || parsed > UINT16_MAX) {
                fprintf(stderr, "UDP port must be between 1 and 65535\n");
                return 2;
            }
            listen_port = (uint16_t)parsed;
            if (strcmp(argv[argument], "--listen") == 0)
                transport = GamepadTransportUDP;
            else if (transport == GamepadTransportSynthetic)
                transport = GamepadTransportVsock;
            if (!duration_was_set) {
                duration = 0.0; // A receiver is normally long-lived.
            }
        } else if (strcmp(argv[argument], "--timeout-ms") == 0) {
            char *end = NULL;
            long parsed = strtol(argv[argument + 1], &end, 10);
            if (!end || *end != '\0' || parsed < 100 || parsed > 10000) {
                fprintf(stderr,
                        "state timeout must be between 100 and 10000 ms\n");
                return 2;
            }
            state_timeout_ms = (uint32_t)parsed;
        } else {
            print_usage(argv[0]);
            return 2;
        }
        argument += 2;
    }

    if (self_test_stream) {
        bool passed = run_stream_protocol_tests();
        fprintf(stderr, "[gamepad-probe] stream protocol tests: %s\n",
                passed ? "passed" : "FAILED");
        return passed ? 0 : 1;
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGHUP, handle_signal);

    CFNumberRef vendor = number_for_int(0xfeed);
    CFNumberRef product = number_for_int(0x4790);
    CFNumberRef version = number_for_int(0x0100);
    CFNumberRef usage_page = number_for_int(0x01);
    CFNumberRef usage = number_for_int(0x05);
    CFNumberRef vendor_source = number_for_int(0x00);
    CFDataRef descriptor = CFDataCreate(kCFAllocatorDefault,
        kGenericGamepadDescriptor, sizeof(kGenericGamepadDescriptor));
    if (!vendor || !product || !version || !usage_page || !usage ||
        !vendor_source || !descriptor) {
        fprintf(stderr, "failed to allocate HID properties\n");
        if (descriptor) CFRelease(descriptor);
        if (vendor_source) CFRelease(vendor_source);
        if (usage) CFRelease(usage);
        if (usage_page) CFRelease(usage_page);
        if (version) CFRelease(version);
        if (product) CFRelease(product);
        if (vendor) CFRelease(vendor);
        return 1;
    }

    const void *keys[] = {
        CFSTR(kIOHIDReportDescriptorKey), CFSTR(kIOHIDTransportKey),
        CFSTR(kIOHIDVendorIDKey), CFSTR(kIOHIDProductIDKey),
        CFSTR(kIOHIDVersionNumberKey), CFSTR(kIOHIDManufacturerKey),
        CFSTR(kIOHIDProductKey), CFSTR(kIOHIDSerialNumberKey),
        CFSTR(kIOHIDPrimaryUsagePageKey), CFSTR(kIOHIDPrimaryUsageKey),
        CFSTR(kIOHIDVendorIDSourceKey),
    };
    const void *values[] = {
        descriptor, CFSTR("VirtualMac"),
        vendor, product, version,
        CFSTR("VirtualMac"), CFSTR("VirtualMac Network Gamepad"),
        CFSTR("virtualmac-gamepad-0"), usage_page, usage,
        vendor_source,
    };
    CFDictionaryRef base_properties = CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, sizeof(keys) / sizeof(keys[0]),
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef properties = base_properties
        ? CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0,
                                        base_properties) : NULL;
    if (base_properties) CFRelease(base_properties);

    dispatch_queue_t queue = dispatch_queue_create("com.virtualmac.gamepad-probe",
                                                   DISPATCH_QUEUE_SERIAL);
    dispatch_semaphore_t cancelled = dispatch_semaphore_create(0);
    IOHIDUserDeviceRef device = NULL;
    if (properties && queue && cancelled) {
        device = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties, 0);
    }
    if (!device) {
        fprintf(stderr,
                "failed to create virtual HID device (check the virtual-device entitlement)\n");
        if (cancelled) dispatch_release(cancelled);
        if (queue) dispatch_release(queue);
        if (properties) CFRelease(properties);
        CFRelease(descriptor);
        CFRelease(usage);
        CFRelease(usage_page);
        CFRelease(vendor_source);
        CFRelease(version);
        CFRelease(product);
        CFRelease(vendor);
        return 1;
    }

    GamepadReportState current_report;
    if (pthread_mutex_init(&current_report.lock, NULL) != 0) {
        fprintf(stderr, "failed to initialize HID report state\n");
        CFRelease(device);
        dispatch_release(cancelled);
        dispatch_release(queue);
        CFRelease(properties);
        CFRelease(descriptor);
        CFRelease(usage);
        CFRelease(usage_page);
        CFRelease(vendor_source);
        CFRelease(version);
        CFRelease(product);
        CFRelease(vendor);
        return 1;
    }
    neutral_report(current_report.report);
    GamepadReportState *current_report_ptr = &current_report;

    IOHIDUserDeviceRegisterGetReportBlock(device,
        ^IOReturn(IOHIDReportType type, uint32_t report_id, uint8_t *report,
                  CFIndex *report_length) {
            if (type != kIOHIDReportTypeInput ||
                (report_id != 0 && report_id != 1)) {
                return kIOReturnUnsupported;
            }
            CFIndex required_length = kGamepadReportLength;
            if (!report || !report_length || *report_length < required_length) {
                return kIOReturnBadArgument;
            }
            load_current_report(current_report_ptr, report);
            *report_length = required_length;
            return kIOReturnSuccess;
        });
    IOHIDUserDeviceRegisterSetReportBlock(device,
        ^IOReturn(IOHIDReportType type, uint32_t report_id, const uint8_t *report,
                  CFIndex report_length) {
            (void)type;
            (void)report_id;
            (void)report;
            (void)report_length;
            return kIOReturnSuccess;
        });
    IOHIDUserDeviceSetDispatchQueue(device, queue);
    IOHIDUserDeviceSetCancelHandler(device, ^{
        dispatch_semaphore_signal(cancelled);
    });
    IOHIDUserDeviceActivate(device);

    int socket_fd = -1;
    if (listen_port) {
        socket_fd = transport == GamepadTransportVsock
            ? create_vsock_listener(listen_port)
            : create_udp_listener(listen_port);
        if (socket_fd < 0) {
            IOHIDUserDeviceCancel(device);
            dispatch_semaphore_wait(cancelled, DISPATCH_TIME_FOREVER);
            CFRelease(device);
            dispatch_release(cancelled);
            dispatch_release(queue);
            pthread_mutex_destroy(&current_report.lock);
            CFRelease(properties);
            CFRelease(descriptor);
            CFRelease(usage);
            CFRelease(usage_page);
            CFRelease(vendor_source);
            CFRelease(version);
            CFRelease(product);
            CFRelease(vendor);
            return 1;
        }
        if (transport == GamepadTransportUDP) {
            int actual_receive_buffer = 0;
            socklen_t actual_receive_buffer_length = sizeof(actual_receive_buffer);
            (void)getsockopt(socket_fd, SOL_SOCKET, SO_RCVBUF,
                             &actual_receive_buffer,
                             &actual_receive_buffer_length);
            fprintf(stderr,
                    "[gamepad-probe] listening on UDP %u "
                    "(state timeout %ums, receive buffer %d bytes)\n",
                    (unsigned)listen_port, (unsigned)state_timeout_ms,
                    actual_receive_buffer);
        } else {
            fprintf(stderr,
                    "[gamepad-probe] listening on AF_VSOCK CID_ANY:%u "
                    "(state timeout %ums)\n",
                    (unsigned)listen_port, (unsigned)state_timeout_ms);
        }
    }
    fprintf(stderr, "[gamepad-probe] active: device=%s "
            "(%u-byte HID reports%s)\n",
            "VirtualMac Network Gamepad feed:4790",
            (unsigned)kGamepadReportLength,
            duration > 0.0 ? ", timed" : ", until interrupted");
    const uint64_t start = monotonic_timestamp();
    uint64_t last_packet_at = 0;
    uint32_t last_sequence = 0;
    uint32_t last_session = 0;
    bool have_sequence = false;
    struct sockaddr_storage active_sender = {0};
    bool have_active_sender = false;
    RetiredGamepadStream retired_streams[kGamepadRetiredStreamCapacity] = {0};
    bool neutralized_for_timeout = true;
    uint64_t last_state_print_at = 0;
    uint16_t last_printed_buttons = 0;
    uint8_t last_printed_hat = 8;
    bool have_printed_state = false;
    uint64_t packets_received = 0;
    uint64_t packets_accepted = 0;
    uint64_t reports_published = 0;
    uint64_t sequence_gaps = 0;
    uint64_t stale_packets = 0;
    uint64_t stream_switches = 0;
    uint64_t malformed_packets = 0;
    uint64_t timeout_count = 0;
    uint64_t last_ack_at = 0;
    uint32_t last_ack_session = 0;
    uint64_t last_stats_at = start;
    uint16_t last_published_buttons = 0;
    uint8_t last_published_hat = 8;
    uint8_t last_published_report[kGamepadReportLength];
    bool have_published_report = false;
    int stream_fd = -1;
    uint8_t stream_buffer[kGamepadStreamBufferBytes];
    size_t stream_length = 0;
    uint8_t stream_ack_buffer[kGamepadAckQueueBytes];
    size_t stream_ack_length = 0;
    bool have_pending_stream_ack = false;
    uint32_t pending_stream_ack_sequence = 0;
    uint32_t pending_stream_ack_session = 0;

    neutral_report(last_published_report);
    IOReturn initial_status = handle_gamepad_report(
        device, current_report_ptr, monotonic_timestamp(),
        last_published_report);
    if (initial_status == kIOReturnSuccess) {
        have_published_report = true;
        reports_published++;
    } else {
        fprintf(stderr, "[gamepad-probe] initial neutral report failed: 0x%08x\n",
                (unsigned)initial_status);
        gStop = 1;
        exit_status = 1;
    }

    while (!gStop) {
        uint64_t now = monotonic_timestamp();
        double elapsed = seconds_between(now, start);
        if (duration > 0.0 && elapsed >= duration) {
            break;
        }

        if (socket_fd < 0) {
            uint8_t report[kGamepadReportLength];
            make_report(report, elapsed);
            IOReturn status = handle_gamepad_report(
                device, current_report_ptr, now, report);
            if (status != kIOReturnSuccess) {
                fprintf(stderr, "[gamepad-probe] report failed: 0x%08x\n",
                        (unsigned)status);
                exit_status = 1;
                break;
            }
            reports_published++;
            usleep(16667);
            continue;
        }

        if (transport == GamepadTransportVsock) {
            fd_set readable, writable;
            FD_ZERO(&readable);
            FD_ZERO(&writable);
            FD_SET(socket_fd, &readable);
            int maximum_fd = socket_fd;
            if (stream_fd >= 0) {
                FD_SET(stream_fd, &readable);
                if (stream_ack_length)
                    FD_SET(stream_fd, &writable);
                if (stream_fd > maximum_fd)
                    maximum_fd = stream_fd;
            }
            struct timeval wait_time = {.tv_sec = 0, .tv_usec = 20000};
            int ready = select(maximum_fd + 1, &readable, &writable, NULL,
                               &wait_time);
            if (ready < 0) {
                if (errno == EINTR)
                    continue;
                fprintf(stderr, "[gamepad-probe] vsock select failed: %s\n",
                        strerror(errno));
                exit_status = 1;
                break;
            }
            bool disconnect_stream = false;
            bool neutralize_stream = false;
            if (ready > 0 && FD_ISSET(socket_fd, &readable)) {
                for (;;) {
                    int accepted = accept(socket_fd, NULL, NULL);
                    if (accepted < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                        break;
                    if (accepted < 0 && errno == EINTR)
                        continue;
                    if (accepted < 0) {
                        fprintf(stderr, "[gamepad-probe] vsock accept failed: %s\n",
                                strerror(errno));
                        exit_status = 1;
                        gStop = 1;
                        break;
                    }
                    if (!make_nonblocking(accepted)) {
                        close(accepted);
                        continue;
                    }
                    int no_signal = 1;
                    (void)setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE,
                                     &no_signal, sizeof(no_signal));
                    if (stream_fd >= 0) {
                        close(stream_fd);
                        stream_switches++;
                    }
                    stream_fd = accepted;
                    stream_length = 0;
                    stream_ack_length = 0;
                    have_pending_stream_ack = false;
                    have_sequence = false;
                    last_packet_at = 0;
                    neutralized_for_timeout = true;
                    neutralize_stream = true;
                    fprintf(stderr,
                            "[gamepad-probe] AF_VSOCK host connected fd=%d\n",
                            stream_fd);
                }
            }
            if (gStop)
                break;
            if (neutralize_stream) {
                uint8_t neutral[kGamepadReportLength];
                neutral_report(neutral);
                IOReturn status = handle_gamepad_report(
                    device, current_report_ptr, monotonic_timestamp(), neutral);
                if (status != kIOReturnSuccess) {
                    exit_status = 1;
                    break;
                }
                memcpy(last_published_report, neutral, sizeof(neutral));
                last_published_buttons = 0;
                last_published_hat = 8;
                have_published_report = true;
                reports_published++;
                neutralized_for_timeout = true;
                neutralize_stream = false;
            }
            if (stream_fd >= 0 && ready > 0 &&
                FD_ISSET(stream_fd, &writable) &&
                flush_stream_acks(stream_fd, stream_ack_buffer,
                                  &stream_ack_length) < 0) {
                disconnect_stream = true;
            }
            bool have_batch_state = false;
            uint8_t batch_report[kGamepadReportLength];
            uint32_t batch_sequence = 0;
            if (!disconnect_stream && stream_fd >= 0 && ready > 0 &&
                FD_ISSET(stream_fd, &readable)) {
                for (;;) {
                    if (stream_length == sizeof(stream_buffer)) {
                        malformed_packets++;
                        disconnect_stream = true;
                        break;
                    }
                    ssize_t received = recv(stream_fd,
                        stream_buffer + stream_length,
                        sizeof(stream_buffer) - stream_length, 0);
                    if (received > 0) {
                        stream_length += (size_t)received;
                        continue;
                    }
                    if (received == 0) {
                        disconnect_stream = true;
                        break;
                    }
                    if (errno == EINTR)
                        continue;
                    if (errno == EAGAIN || errno == EWOULDBLOCK)
                        break;
                    disconnect_stream = true;
                    break;
                }
                while (!disconnect_stream &&
                       stream_length >= kGamepadPacketLength) {
                    uint8_t packet[kGamepadPacketLength];
                    memcpy(packet, stream_buffer, sizeof(packet));
                    memmove(stream_buffer, stream_buffer + sizeof(packet),
                            stream_length - sizeof(packet));
                    stream_length -= sizeof(packet);
                    packets_received++;
                    uint32_t sequence = 0, session = 0;
                    uint8_t report[kGamepadReportLength];
                    if (!decode_state_packet(packet, &sequence, &session,
                                             report)) {
                        malformed_packets++;
                        disconnect_stream = true;
                        break;
                    }
                    uint64_t packet_now = monotonic_timestamp();
                    if (have_sequence && session != last_session) {
                        have_sequence = false;
                        stream_switches++;
                        uint8_t neutral[kGamepadReportLength];
                        neutral_report(neutral);
                        IOReturn status = handle_gamepad_report(
                            device, current_report_ptr,
                            monotonic_timestamp(), neutral);
                        if (status != kIOReturnSuccess) {
                            exit_status = 1;
                            gStop = 1;
                            break;
                        }
                        memcpy(last_published_report, neutral,
                               sizeof(neutral));
                        last_published_buttons = 0;
                        last_published_hat = 8;
                        have_published_report = true;
                        reports_published++;
                    }
                    if (have_sequence &&
                        !packet_is_newer(sequence, last_sequence)) {
                        stale_packets++;
                        continue;
                    }
                    if (have_sequence) {
                        uint32_t distance = sequence - last_sequence;
                        if (distance > 1)
                            sequence_gaps += (uint64_t)distance - 1;
                    }
                    last_sequence = sequence;
                    last_session = session;
                    have_sequence = true;
                    last_packet_at = packet_now;
                    neutralized_for_timeout = false;
                    packets_accepted++;
                    have_pending_stream_ack = true;
                    pending_stream_ack_sequence = sequence;
                    pending_stream_ack_session = session;
                    uint16_t report_buttons = (uint16_t)report[1] |
                        (uint16_t)report[2] << 8;
                    bool digital_transition = !have_published_report ||
                        report_buttons != last_published_buttons ||
                        report[15] != last_published_hat ||
                        trigger_is_pressed(report, 11) !=
                            trigger_is_pressed(last_published_report, 11) ||
                        trigger_is_pressed(report, 13) !=
                            trigger_is_pressed(last_published_report, 13);
                    if (digital_transition) {
                        IOReturn status = handle_gamepad_report(
                            device, current_report_ptr, monotonic_timestamp(),
                            report);
                        if (status != kIOReturnSuccess) {
                            fprintf(stderr,
                                    "[gamepad-probe] report failed: 0x%08x\n",
                                    (unsigned)status);
                            exit_status = 1;
                            gStop = 1;
                            break;
                        }
                        reports_published++;
                        last_published_buttons = report_buttons;
                        last_published_hat = report[15];
                        memcpy(last_published_report, report,
                               sizeof(last_published_report));
                        have_published_report = true;
                        if (!queue_stream_ack(stream_ack_buffer,
                                &stream_ack_length, sequence, session)) {
                            disconnect_stream = true;
                            break;
                        }
                        last_ack_at = monotonic_timestamp();
                        last_ack_session = session;
                        have_pending_stream_ack = false;
                    }
                    memcpy(batch_report, report, sizeof(batch_report));
                    batch_sequence = sequence;
                    have_batch_state = true;
                }
            }
            if (gStop)
                break;
            if (!disconnect_stream && have_batch_state &&
                (!have_published_report ||
                 memcmp(batch_report, last_published_report,
                        sizeof(last_published_report)) != 0)) {
                IOReturn status = handle_gamepad_report(
                    device, current_report_ptr, monotonic_timestamp(),
                    batch_report);
                if (status != kIOReturnSuccess) {
                    fprintf(stderr, "[gamepad-probe] report failed: 0x%08x\n",
                            (unsigned)status);
                    exit_status = 1;
                    break;
                }
                reports_published++;
                last_published_buttons = (uint16_t)batch_report[1] |
                    (uint16_t)batch_report[2] << 8;
                last_published_hat = batch_report[15];
                memcpy(last_published_report, batch_report,
                       sizeof(last_published_report));
                have_published_report = true;
            }
            uint64_t ack_now = monotonic_timestamp();
            bool periodic_ack_due = have_pending_stream_ack &&
                (!last_ack_at ||
                 pending_stream_ack_session != last_ack_session ||
                 seconds_between(ack_now, last_ack_at) >= 0.25);
            if (!disconnect_stream && periodic_ack_due) {
                if (!queue_stream_ack(stream_ack_buffer, &stream_ack_length,
                                      pending_stream_ack_sequence,
                                      pending_stream_ack_session)) {
                    disconnect_stream = true;
                } else {
                    last_ack_at = ack_now;
                    last_ack_session = pending_stream_ack_session;
                    have_pending_stream_ack = false;
                }
            }
            if (!disconnect_stream && stream_fd >= 0 && stream_ack_length &&
                flush_stream_acks(stream_fd, stream_ack_buffer,
                                  &stream_ack_length) < 0)
                disconnect_stream = true;
            if (have_batch_state && print_received_state) {
                uint64_t print_now = monotonic_timestamp();
                uint16_t buttons = (uint16_t)batch_report[1] |
                    (uint16_t)batch_report[2] << 8;
                if (!have_printed_state || buttons != last_printed_buttons ||
                    batch_report[15] != last_printed_hat ||
                    seconds_between(print_now, last_state_print_at) >= 0.10) {
                    print_state(batch_sequence, batch_report);
                    last_state_print_at = print_now;
                    last_printed_buttons = buttons;
                    last_printed_hat = batch_report[15];
                    have_printed_state = true;
                }
            }
            if (disconnect_stream && stream_fd >= 0) {
                fprintf(stderr,
                        "[gamepad-probe] AF_VSOCK host disconnected; neutralized\n");
                close(stream_fd);
                stream_fd = -1;
                stream_length = 0;
                stream_ack_length = 0;
                have_pending_stream_ack = false;
                have_sequence = false;
                neutralize_stream = true;
            }
            if (neutralize_stream) {
                uint8_t neutral[kGamepadReportLength];
                neutral_report(neutral);
                IOReturn status = handle_gamepad_report(
                    device, current_report_ptr, monotonic_timestamp(), neutral);
                if (status != kIOReturnSuccess) {
                    exit_status = 1;
                    break;
                }
                memcpy(last_published_report, neutral, sizeof(neutral));
                last_published_buttons = 0;
                last_published_hat = 8;
                have_published_report = true;
                reports_published++;
                neutralized_for_timeout = true;
            }
        } else {
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(socket_fd, &readable);
        struct timeval wait_time = {.tv_sec = 0, .tv_usec = 20000};
        int ready = select(socket_fd + 1, &readable, NULL, NULL, &wait_time);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "[gamepad-probe] select failed: %s\n",
                    strerror(errno));
            exit_status = 1;
            break;
        }
        if (ready > 0 && FD_ISSET(socket_fd, &readable)) {
            bool have_batch_state = false;
            uint8_t batch_report[kGamepadReportLength];
            uint32_t batch_sequence = 0;
            bool have_ack_candidate = false;
            bool force_batch_ack = false;
            struct sockaddr_storage ack_sender = {0};
            socklen_t ack_sender_length = 0;
            uint32_t ack_sequence = 0;
            uint32_t ack_session = 0;
            for (unsigned batch = 0; batch < kGamepadMaxBatchPackets; batch++) {
                // One extra byte makes an oversized datagram fail the exact-size
                // check instead of accepting a valid-looking truncated prefix.
                uint8_t packet[kGamepadPacketLength + 1];
                struct sockaddr_storage sender = {0};
                socklen_t sender_length = sizeof(sender);
                ssize_t received = recvfrom(socket_fd, packet, sizeof(packet), 0,
                    (struct sockaddr *)&sender, &sender_length);
                if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                    break;
                if (received < 0 && errno == EINTR)
                    continue;
                if (received < 0) {
                    fprintf(stderr, "[gamepad-probe] UDP receive failed: %s\n",
                            strerror(errno));
                    exit_status = 1;
                    gStop = 1;
                    break;
                }
                packets_received++;
                uint32_t sequence = 0;
                uint32_t session = 0;
                uint8_t report[kGamepadReportLength];
                if (received != kGamepadPacketLength ||
                    !decode_state_packet(packet, &sequence, &session, report)) {
                    malformed_packets++;
                    continue;
                }
                uint64_t packet_now = monotonic_timestamp();
                bool same_sender = have_active_sender &&
                    socket_addresses_equal(&sender, &active_sender);
                bool same_stream = same_sender && have_sequence &&
                    session == last_session;
                bool stream_changed = !same_stream;
                if (stream_changed) {
                    if (retired_stream_matches(retired_streams, &sender,
                                               session, packet_now)) {
                        stale_packets++;
                        continue;
                    }
                    bool had_active_stream = have_active_sender &&
                        have_sequence;
                    if (had_active_stream) {
                        retire_stream(retired_streams, &active_sender,
                                      last_session, packet_now);
                        stream_switches++;
                    }
                    // This development bridge intentionally favors immediate
                    // recovery after an app/network restart over sender
                    // authentication. A previously unseen valid stream takes
                    // over, while delayed packets from recently retired
                    // streams are ignored above.
                    active_sender = sender;
                    have_active_sender = true;
                    have_sequence = false;
                }
                if (have_sequence && session == last_session &&
                    !packet_is_newer(sequence, last_sequence)) {
                    stale_packets++;
                    continue;
                }
                if (have_sequence && session == last_session) {
                    uint32_t distance = sequence - last_sequence;
                    if (distance > 1)
                        sequence_gaps += (uint64_t)distance - 1;
                }
                last_sequence = sequence;
                last_session = session;
                have_sequence = true;
                last_packet_at = packet_now;
                neutralized_for_timeout = false;
                packets_accepted++;
                memcpy(batch_report, report, sizeof(batch_report));
                batch_sequence = sequence;
                have_batch_state = true;
                uint16_t report_buttons = (uint16_t)report[1] |
                    (uint16_t)report[2] << 8;
                bool digital_transition = !have_published_report ||
                    report_buttons != last_published_buttons ||
                    report[15] != last_published_hat ||
                    trigger_is_pressed(report, 11) !=
                        trigger_is_pressed(last_published_report, 11) ||
                    trigger_is_pressed(report, 13) !=
                        trigger_is_pressed(last_published_report, 13);
                if (digital_transition) {
                    IOReturn status = handle_gamepad_report(
                        device, current_report_ptr, monotonic_timestamp(),
                        report);
                    if (status != kIOReturnSuccess) {
                        fprintf(stderr,
                                "[gamepad-probe] report failed: 0x%08x\n",
                                (unsigned)status);
                        gStop = 1;
                        exit_status = 1;
                        break;
                    }
                    reports_published++;
                    last_published_buttons = report_buttons;
                    last_published_hat = report[15];
                    memcpy(last_published_report, report,
                           sizeof(last_published_report));
                    have_published_report = true;
                }
                // Keep only the newest accepted state in this drain cycle. ACK
                // once after the batch so it never acknowledges an older packet
                // while a newer one is already waiting in the socket.
                ack_sender = sender;
                ack_sender_length = sender_length;
                ack_sequence = sequence;
                ack_session = session;
                have_ack_candidate = true;
                force_batch_ack |= stream_changed;
            }
            if (gStop)
                break;
            bool latest_state_changed = have_batch_state &&
                (!have_published_report ||
                 memcmp(batch_report, last_published_report,
                        sizeof(last_published_report)) != 0);
            if (latest_state_changed) {
                uint64_t publish_now = monotonic_timestamp();
                IOReturn status = handle_gamepad_report(
                    device, current_report_ptr, publish_now, batch_report);
                if (status != kIOReturnSuccess) {
                    fprintf(stderr, "[gamepad-probe] report failed: 0x%08x\n",
                            (unsigned)status);
                    exit_status = 1;
                    break;
                }
                reports_published++;
                last_published_buttons = (uint16_t)batch_report[1] |
                    (uint16_t)batch_report[2] << 8;
                last_published_hat = batch_report[15];
                memcpy(last_published_report, batch_report,
                       sizeof(last_published_report));
                have_published_report = true;
            }
            if (have_batch_state) {
                uint64_t publish_now = monotonic_timestamp();
                uint16_t buttons = (uint16_t)batch_report[1] |
                    (uint16_t)batch_report[2] << 8;
                if (print_received_state &&
                    (!have_printed_state || buttons != last_printed_buttons ||
                     batch_report[15] != last_printed_hat ||
                     seconds_between(publish_now, last_state_print_at) >= 0.10)) {
                    print_state(batch_sequence, batch_report);
                    last_state_print_at = publish_now;
                    last_printed_buttons = buttons;
                    last_printed_hat = batch_report[15];
                    have_printed_state = true;
                }
            }
            uint64_t ack_now = monotonic_timestamp();
            bool ack_due = have_ack_candidate &&
                (force_batch_ack || !last_ack_at ||
                 ack_session != last_ack_session ||
                 seconds_between(ack_now, last_ack_at) >= 0.25);
            if (ack_due &&
                send_ack(socket_fd, (const struct sockaddr *)&ack_sender,
                         ack_sender_length, ack_sequence, ack_session)) {
                last_ack_at = ack_now;
                last_ack_session = ack_session;
            }
        }
        }
        now = monotonic_timestamp();
        if (last_packet_at && !neutralized_for_timeout &&
            seconds_between(now, last_packet_at) * 1000.0 >=
                state_timeout_ms) {
            uint8_t neutral[kGamepadReportLength];
            neutral_report(neutral);
            IOReturn status = handle_gamepad_report(
                device, current_report_ptr, now, neutral);
            if (status != kIOReturnSuccess) {
                fprintf(stderr, "[gamepad-probe] neutral report failed: 0x%08x\n",
                        (unsigned)status);
                exit_status = 1;
                break;
            }
            memcpy(last_published_report, neutral,
                   sizeof(last_published_report));
            last_published_buttons = 0;
            last_published_hat = 8;
            have_published_report = true;
            reports_published++;
            neutralized_for_timeout = true;
            timeout_count++;
            fprintf(stderr,
                    "[gamepad-probe] state timed out after %ums; neutralized\n",
                    (unsigned)state_timeout_ms);
        }
        if (print_stats && seconds_between(now, last_stats_at) >= 10.0) {
            fprintf(stderr,
                    "[gamepad-probe] stats received=%llu accepted=%llu "
                    "published=%llu sequence-gaps=%llu stale=%llu "
                    "session-switches=%llu malformed=%llu "
                    "timeouts=%llu\n",
                    packets_received, packets_accepted, reports_published,
                    sequence_gaps, stale_packets, stream_switches,
                    malformed_packets, timeout_count);
            last_stats_at = now;
        }
    }

    uint8_t neutral[kGamepadReportLength];
    neutral_report(neutral);
    IOReturn neutral_status = handle_gamepad_report(
        device, current_report_ptr, monotonic_timestamp(), neutral);
    if (neutral_status == kIOReturnSuccess) {
        reports_published++;
    } else {
        fprintf(stderr, "[gamepad-probe] final neutral report failed: 0x%08x\n",
                (unsigned)neutral_status);
        exit_status = 1;
    }
    IOHIDUserDeviceCancel(device);
    // GetReport captures current_report. Wait for IOHID cancellation to finish
    // before destroying that mutex-backed state; this is process teardown and
    // has no useful timeout/recovery path.
    dispatch_semaphore_wait(cancelled, DISPATCH_TIME_FOREVER);
    fprintf(stderr,
            "[gamepad-probe] stopped: received=%llu accepted=%llu "
            "published=%llu sequence-gaps=%llu stale=%llu "
            "session-switches=%llu malformed=%llu timeouts=%llu\n",
            packets_received, packets_accepted, reports_published,
            sequence_gaps, stale_packets, stream_switches,
            malformed_packets, timeout_count);

    if (socket_fd >= 0) {
        close(socket_fd);
    }
    if (stream_fd >= 0) {
        close(stream_fd);
    }
    CFRelease(device);
    dispatch_release(cancelled);
    dispatch_release(queue);
    pthread_mutex_destroy(&current_report.lock);
    CFRelease(properties);
    CFRelease(descriptor);
    CFRelease(usage);
    CFRelease(usage_page);
    CFRelease(vendor_source);
    CFRelease(version);
    CFRelease(product);
    CFRelease(vendor);
    return exit_status;
}
