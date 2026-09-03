#include <arpa/inet.h>
#include <math.h>
#include <netdb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

enum { kPacketLength = 32, kReportLength = 16 };

static void write_be16(uint8_t *value, uint16_t input) {
    value[0] = (uint8_t)(input >> 8);
    value[1] = (uint8_t)input;
}

static void write_be32(uint8_t *value, uint32_t input) {
    value[0] = (uint8_t)(input >> 24);
    value[1] = (uint8_t)(input >> 16);
    value[2] = (uint8_t)(input >> 8);
    value[3] = (uint8_t)input;
}

static void make_packet(uint8_t packet[kPacketLength], uint32_t sequence,
                        uint32_t session, double seconds) {
    memset(packet, 0, kPacketLength);
    write_be32(&packet[0], 0x564D4750); // VMGP
    packet[4] = 1;
    packet[5] = 1;
    write_be16(&packet[6], kReportLength);
    write_be32(&packet[8], sequence);
    write_be32(&packet[12], session);
    uint8_t *report = &packet[16];
    report[0] = 1;
    report[1] = seconds < 1.0 ? 1 : 0;
    int16_t x = (int16_t)lrint(sin(seconds * 6.28318530718) * 25000.0);
    memcpy(&report[3], &x, sizeof(x));
    report[15] = 8;
}

int main(int argc, char **argv) {
    if (argc != 7 || strcmp(argv[1], "--host") || strcmp(argv[3], "--port") ||
        strcmp(argv[5], "--duration")) {
        fprintf(stderr, "usage: %s --host HOST --port PORT --duration SECONDS\n", argv[0]);
        return 2;
    }
    long port = strtol(argv[4], NULL, 10);
    double duration = strtod(argv[6], NULL);
    if (port < 1 || port > 65535 || !(duration > 0.0)) return 2;
    struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_DGRAM};
    struct addrinfo *destination = NULL;
    if (getaddrinfo(argv[2], argv[4], &hints, &destination) != 0) return 1;
    int fd = socket(destination->ai_family, destination->ai_socktype, 0);
    if (fd < 0) return 1;
    unsigned iterations = (unsigned)ceil(duration * 60.0);
    uint32_t session = arc4random();
    if (!session) session = 1;
    for (unsigned index = 0; index < iterations; index++) {
        uint8_t packet[kPacketLength];
        make_packet(packet, index + 1, session, (double)index / 60.0);
        if (sendto(fd, packet, sizeof(packet), 0, destination->ai_addr,
                   destination->ai_addrlen) != sizeof(packet)) break;
        usleep(16667);
    }
    close(fd);
    freeaddrinfo(destination);
    return 0;
}
