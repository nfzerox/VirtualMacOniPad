#include "VZPaths.h"
#import "VZGuestRuntimePolicy.h"

#if EXPERIMENT_GDB_DEBUG

#import <mach-o/loader.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <arpa/inet.h>
#import <ctype.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <stdio.h>
#import <unistd.h>

static NSString * const VZGuestRuntimePolicyErrorDomain =
    @"VirtualMacGuestRuntimePolicy";
static const uint16_t kDebugStubPort = 12345;

typedef struct {
    int descriptor;
    uint8_t input[64 * 1024];
    size_t inputOffset;
    size_t inputLength;
    BOOL noAcknowledgements;
} VZGDBRemote;

static SEL S(const char *name)
{
    return sel_registerName(name);
}

static NSError *PolicyError(NSInteger code, NSString *description)
{
    return [NSError errorWithDomain:VZGuestRuntimePolicyErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL SendAll(int descriptor, const void *bytes, size_t length)
{
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t sent = send(descriptor, cursor, length, 0);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return NO;
        cursor += sent;
        length -= (size_t)sent;
    }
    return YES;
}

static int RemoteByte(VZGDBRemote *remote)
{
    if (remote->inputOffset == remote->inputLength) {
        ssize_t count;
        do {
            count = recv(remote->descriptor, remote->input,
                         sizeof(remote->input), 0);
        } while (count < 0 && errno == EINTR);
        if (count <= 0) return -1;
        remote->inputOffset = 0;
        remote->inputLength = (size_t)count;
    }
    return remote->input[remote->inputOffset++];
}

static NSData *ReceivePacket(VZGDBRemote *remote, NSError **error)
{
    int byte;
    do {
        byte = RemoteByte(remote);
    } while (byte >= 0 && byte != '$');
    if (byte < 0) {
        if (error) *error = PolicyError(2, @"The guest debug connection closed.");
        return nil;
    }
    NSMutableData *payload = [NSMutableData data];
    uint8_t checksum = 0;
    while ((byte = RemoteByte(remote)) >= 0 && byte != '#') {
        uint8_t value = (uint8_t)byte;
        [payload appendBytes:&value length:1];
        checksum += value;
    }
    int high = RemoteByte(remote), low = RemoteByte(remote);
    if (byte < 0 || high < 0 || low < 0) {
        if (error) *error = PolicyError(3, @"The guest debug reply was incomplete.");
        return nil;
    }
    char expected[3];
    snprintf(expected, sizeof(expected), "%02x", checksum);
    if (tolower(high) != expected[0] || tolower(low) != expected[1]) {
        SendAll(remote->descriptor, "-", 1);
        if (error) *error = PolicyError(4, @"The guest debug checksum was invalid.");
        return nil;
    }
    if (!remote->noAcknowledgements)
        SendAll(remote->descriptor, "+", 1);
    return payload;
}

static NSData *RemoteRequest(VZGDBRemote *remote, NSString *request,
                             NSError **error)
{
    NSData *payload = [request dataUsingEncoding:NSASCIIStringEncoding];
    uint8_t checksum = 0;
    for (NSUInteger index = 0; index < payload.length; ++index)
        checksum += ((const uint8_t *)payload.bytes)[index];
    NSString *suffix = [NSString stringWithFormat:@"#%02x", checksum];
    if (!SendAll(remote->descriptor, "$", 1) ||
        !SendAll(remote->descriptor, payload.bytes, payload.length) ||
        !SendAll(remote->descriptor, suffix.UTF8String, 3)) {
        if (error) *error = PolicyError(5, @"The guest debug request could not be sent.");
        return nil;
    }
    if (!remote->noAcknowledgements) {
        int byte;
        do {
            byte = RemoteByte(remote);
        } while (byte >= 0 && byte != '+');
        if (byte < 0) {
            if (error) *error = PolicyError(6, @"The guest did not acknowledge the debug request.");
            return nil;
        }
    }
    return ReceivePacket(remote, error);
}

static BOOL RemoteConnect(VZGDBRemote *remote, NSError **error)
{
    memset(remote, 0, sizeof(*remote));
    remote->descriptor = -1;
    for (NSUInteger attempt = 0; attempt < 100; ++attempt) {
        int descriptor = socket(AF_INET, SOCK_STREAM, 0);
        if (descriptor < 0) break;
        struct timeval timeout = { .tv_sec = 5, .tv_usec = 0 };
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   sizeof(timeout));
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   sizeof(timeout));
        struct sockaddr_in address = {
            .sin_len = sizeof(address),
            .sin_family = AF_INET,
            .sin_port = htons(kDebugStubPort),
            .sin_addr = { .s_addr = htonl(INADDR_LOOPBACK) },
        };
        if (connect(descriptor, (struct sockaddr *)&address,
                    sizeof(address)) == 0) {
            remote->descriptor = descriptor;
            SendAll(descriptor, "+", 1);
            NSData *reply = RemoteRequest(remote, @"QStartNoAckMode", error);
            if ([reply isEqualToData:[@"OK" dataUsingEncoding:
                                      NSASCIIStringEncoding]]) {
                remote->noAcknowledgements = YES;
                return YES;
            }
            close(descriptor);
            remote->descriptor = -1;
            return NO;
        }
        close(descriptor);
        usleep(100 * 1000);
    }
    if (error) *error = PolicyError(7,
        @"The guest early-boot debug endpoint was unavailable.");
    return NO;
}

static void RemoteDetach(VZGDBRemote *remote)
{
    if (remote->descriptor < 0) return;
    NSError *ignored = nil;
    RemoteRequest(remote, @"D", &ignored);
    close(remote->descriptor);
    remote->descriptor = -1;
}

static NSData *UnescapeBinary(NSData *data, NSError **error)
{
    NSMutableData *result = [NSMutableData dataWithCapacity:data.length];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; ++index) {
        uint8_t value = bytes[index];
        if (value == '}') {
            if (++index >= data.length) {
                if (error) *error = PolicyError(8,
                    @"The guest memory reply ended in an escape byte.");
                return nil;
            }
            value = bytes[index] ^ 0x20;
        }
        [result appendBytes:&value length:1];
    }
    return result;
}

static NSData *RemoteRead(VZGDBRemote *remote, uint64_t address,
                          NSUInteger length, NSError **error)
{
    NSData *reply = RemoteRequest(remote, [NSString stringWithFormat:
        @"x%llx,%lx", address, (unsigned long)length], error);
    if (!reply) return nil;
    const uint8_t *bytes = reply.bytes;
    if (reply.length == 3 && bytes[0] == 'E' &&
        isxdigit(bytes[1]) && isxdigit(bytes[2])) {
        if (error) *error = PolicyError(9,
            @"The guest rejected a kernel memory read.");
        return nil;
    }
    NSData *result = UnescapeBinary(reply, error);
    if (result.length != length) {
        if (error && !*error) *error = PolicyError(10,
            @"The guest returned an incomplete kernel memory read.");
        return nil;
    }
    return result;
}

static BOOL RemoteWrite(VZGDBRemote *remote, uint64_t address, NSData *data,
                        NSError **error)
{
    const uint8_t *bytes = data.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger index = 0; index < data.length; ++index)
        [hex appendFormat:@"%02x", bytes[index]];
    NSData *reply = RemoteRequest(remote, [NSString stringWithFormat:
        @"M%llx,%lx:%@", address, (unsigned long)data.length, hex], error);
    if (![reply isEqualToData:[@"OK" dataUsingEncoding:NSASCIIStringEncoding]]) {
        if (error && !*error) *error = PolicyError(11,
            @"The guest rejected a kernel memory write.");
        return NO;
    }
    return YES;
}

static uint64_t ParseProgramCounter(NSData *stopReply)
{
    NSString *text = [[[NSString alloc] initWithData:stopReply
        encoding:NSASCIIStringEncoding] autorelease];
    for (NSString *field in [text componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@",;"]]) {
        if (![field hasPrefix:@"20:"]) continue;
        NSString *hex = [field substringFromIndex:3];
        if (hex.length != 16) return 0;
        uint64_t value = 0;
        for (NSUInteger index = 0; index < 8; ++index) {
            unsigned byte = 0;
            NSScanner *scanner = [NSScanner scannerWithString:
                [hex substringWithRange:NSMakeRange(index * 2, 2)]];
            if (![scanner scanHexInt:&byte]) return 0;
            value |= (uint64_t)byte << (index * 8);
        }
        return value;
    }
    return 0;
}

typedef struct {
    uint64_t textAddress;
    uint64_t textSize;
    uint64_t executeAddress;
    uint64_t executeSize;
    uint64_t imageStart;
    uint64_t imageEnd;
    struct {
        uint64_t address;
        uint64_t size;
    } data[8];
    NSUInteger dataCount;
} VZKernelSegments;

static BOOL FindKernel(VZGDBRemote *remote, uint64_t pc,
                       uint64_t *kernelAddress, VZKernelSegments *segments,
                       NSError **error)
{
    uint64_t page = pc & ~UINT64_C(0x3fff);
    for (NSUInteger attempt = 0; attempt < (128 * 1024 * 1024 / 0x4000);
         ++attempt, page -= 0x4000) {
        NSData *headerData = RemoteRead(remote, page,
            sizeof(struct mach_header_64), nil);
        if (headerData.length != sizeof(struct mach_header_64)) continue;
        const struct mach_header_64 *header = headerData.bytes;
        if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
            (header->filetype != MH_EXECUTE && header->filetype != MH_FILESET) ||
            !header->ncmds || header->ncmds >= 1000 ||
            header->sizeofcmds > 1024 * 1024)
            continue;
        NSData *commands = RemoteRead(remote,
            page + sizeof(struct mach_header_64), header->sizeofcmds, nil);
        if (commands.length != header->sizeofcmds) continue;
        const uint8_t *cursor = commands.bytes;
        NSUInteger remaining = commands.length;
        VZKernelSegments found = {0};
        BOOL valid = YES;
        for (uint32_t index = 0; index < header->ncmds; ++index) {
            if (remaining < sizeof(struct load_command)) { valid = NO; break; }
            const struct load_command *command = (const void *)cursor;
            if (command->cmdsize < sizeof(*command) ||
                command->cmdsize > remaining) { valid = NO; break; }
            if (command->cmd == LC_SEGMENT_64 &&
                command->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)cursor;
                if (segment->vmsize) {
                    found.imageStart = found.imageStart
                        ? MIN(found.imageStart, segment->vmaddr)
                        : segment->vmaddr;
                    found.imageEnd = MAX(found.imageEnd,
                        segment->vmaddr + segment->vmsize);
                }
                if (!strncmp(segment->segname, "__TEXT", 16)) {
                    found.textAddress = segment->vmaddr;
                    found.textSize = segment->vmsize;
                } else if (!strncmp(segment->segname, "__TEXT_EXEC", 16)) {
                    found.executeAddress = segment->vmaddr;
                    found.executeSize = segment->vmsize;
                } else if ((!strncmp(segment->segname, "__DATA", 6) ||
                            !strncmp(segment->segname, "__BOOTDATA", 10)) &&
                           found.dataCount < 8 && segment->vmsize <=
                               UINT64_C(64) * 1024 * 1024) {
                    found.data[found.dataCount].address = segment->vmaddr;
                    found.data[found.dataCount].size = segment->vmsize;
                    found.dataCount++;
                }
            }
            cursor += command->cmdsize;
            remaining -= command->cmdsize;
        }
        if (valid && found.textAddress && found.executeAddress) {
            dprintf(STDERR_FILENO,
                "[GuestPolicy] kernel segments data=%lu image=[%p,%p)\n",
                (unsigned long)found.dataCount, (void *)found.imageStart,
                (void *)found.imageEnd);
            *kernelAddress = page;
            *segments = found;
            return YES;
        }
    }
    if (error) *error = PolicyError(12,
        @"The running guest kernel could not be identified.");
    return NO;
}

static int64_t SignExtend(uint64_t value, unsigned bits)
{
    uint64_t sign = UINT64_C(1) << (bits - 1);
    return (int64_t)((value ^ sign) - sign);
}

static uint64_t DecodeADRP(uint64_t pc, uint32_t instruction)
{
    uint64_t immediate = (((instruction >> 5) & 0x7ffff) << 2) |
                         ((instruction >> 29) & 3);
    return (uint64_t)((int64_t)(pc & ~UINT64_C(0xfff)) +
        (SignExtend(immediate, 21) << 12));
}

// XNU's public boot_args ABI has remained stable across the macOS releases
// supported by Virtual Mac. See Apple XNU's arm64 boot.h:
// https://github.com/apple-oss-distributions/xnu/blob/xnu-8019.80.24/pexpert/pexpert/arm64/boot.h
//
// Older kernels inline PE_boot_args differently, so an instruction signature
// alone is not a reliable way to find PE_state.bootArgs. Validate the pointed-
// to structure instead. This runs once while the guest is stopped in early
// boot; it is not part of a vCPU or graphics hot path.
static BOOL LooksLikeBootArgs(NSData *data)
{
    if (data.length < 128) return NO;
    const uint8_t *bytes = data.bytes;
    uint16_t revision = 0, version = 0;
    uint64_t virtualBase = 0, physicalBase = 0, memorySize = 0;
    uint64_t topOfKernelData = 0, deviceTree = 0;
    uint32_t deviceTreeLength = 0;
    memcpy(&revision, bytes, sizeof(revision));
    memcpy(&version, bytes + 2, sizeof(version));
    memcpy(&virtualBase, bytes + 8, sizeof(virtualBase));
    memcpy(&physicalBase, bytes + 16, sizeof(physicalBase));
    memcpy(&memorySize, bytes + 24, sizeof(memorySize));
    memcpy(&topOfKernelData, bytes + 32, sizeof(topOfKernelData));
    memcpy(&deviceTree, bytes + 96, sizeof(deviceTree));
    memcpy(&deviceTreeLength, bytes + 104, sizeof(deviceTreeLength));
    // macOS 26 uses revision 3 while retaining the same prefix and command
    // line offset. Leave room for another additive revision, but keep the
    // remaining physical-memory and Device Tree checks strict.
    if (revision < 1 || revision > 4 || version < 1 || version > 2 ||
        (virtualBase & 0xfff) || (physicalBase & 0xfff) ||
        memorySize < UINT64_C(128) * 1024 * 1024 ||
        memorySize > UINT64_C(1024) * 1024 * 1024 * 1024 ||
        topOfKernelData < physicalBase ||
        topOfKernelData > physicalBase + memorySize ||
        deviceTree < UINT64_C(0xffff000000000000) ||
        !deviceTreeLength || deviceTreeLength > 64 * 1024 * 1024)
        return NO;
    // The command line may legitimately be empty. Reject control bytes in the
    // prefix so an unrelated structure with the same small header cannot win.
    for (NSUInteger index = 108; index < MIN(data.length, (NSUInteger)128);
         ++index) {
        uint8_t byte = bytes[index];
        if (!byte) break;
        if (byte < 0x20 || byte > 0x7e) return NO;
    }
    return YES;
}

static BOOL FindBootArgsPointerByData(VZGDBRemote *remote,
                                      const VZKernelSegments *segments,
                                      uint64_t slide,
                                      uint64_t *bootArgsPointer,
                                      NSError **error)
{
    const NSUInteger chunkSize = 256 * 1024;
    uint64_t liveImageStart = segments->imageStart + slide;
    uint64_t liveImageEnd = segments->imageEnd + slide;
    // In practice only PE_state and a few early-boot globals point outside the
    // kernel image. Keep a small deduplicated list, then validate those targets
    // after the bulk segment reads have completed.
    NSMutableData *targetStorage = [NSMutableData dataWithLength:
        8192 * sizeof(uint64_t)];
    NSMutableData *slotStorage = [NSMutableData dataWithLength:
        8192 * sizeof(uint64_t)];
    uint64_t *targets = targetStorage.mutableBytes;
    uint64_t *slots = slotStorage.mutableBytes;
    BOOL captureCandidates = [[NSFileManager defaultManager]
        fileExistsAtPath:@(VZTemporaryPath("vz-dump-guest-kernel"))];
    NSMutableData *candidateCapture = captureCandidates
        ? [NSMutableData data] : nil;
    for (NSUInteger candidateClass = 0; candidateClass < 2;
         ++candidateClass) {
        NSUInteger targetCount = 0;
        for (NSUInteger segmentIndex = 0;
             segmentIndex < segments->dataCount; ++segmentIndex) {
            uint64_t start = segments->data[segmentIndex].address + slide;
            uint64_t size = segments->data[segmentIndex].size;
            for (uint64_t offset = 0; offset < size; offset += chunkSize) {
                NSUInteger length = (NSUInteger)MIN((uint64_t)chunkSize,
                                                     size - offset);
                NSData *data = RemoteRead(remote, start + offset, length,
                                          error);
                if (!data) return NO;
                const uint8_t *bytes = data.bytes;
                for (NSUInteger position = 0; position + 8 <= length;
                     position += 8) {
                    uint64_t target = 0;
                    memcpy(&target, bytes + position, sizeof(target));
                    BOOL pointsIntoData = NO;
                    for (NSUInteger targetSegment = 0;
                         targetSegment < segments->dataCount;
                         ++targetSegment) {
                        uint64_t dataStart =
                            segments->data[targetSegment].address + slide;
                        uint64_t dataEnd = dataStart +
                            segments->data[targetSegment].size;
                        if (target >= dataStart && target < dataEnd) {
                            pointsIntoData = YES;
                            break;
                        }
                    }
                    BOOL pointsOutsideImage =
                        target < liveImageStart || target >= liveImageEnd;
                    if (target < UINT64_C(0xffff000000000000) ||
                        (candidateClass == 0 && !pointsOutsideImage) ||
                        (candidateClass == 1 && !pointsIntoData))
                        continue;
                    BOOL duplicate = NO;
                    for (NSUInteger index = 0; index < targetCount; ++index) {
                        if (targets[index] == target) {
                            duplicate = YES;
                            break;
                        }
                    }
                    if (duplicate || targetCount == 8192) continue;
                    targets[targetCount] = target;
                    slots[targetCount] = start + offset + position;
                    targetCount++;
                }
            }
        }
        for (NSUInteger index = 0; index < targetCount; ++index) {
            NSData *candidate = RemoteRead(remote, targets[index], 128, nil);
            if (candidateCapture && candidate.length == 128) {
                [candidateCapture appendBytes:&slots[index] length:8];
                [candidateCapture appendBytes:&targets[index] length:8];
                [candidateCapture appendData:candidate];
            }
            if (!LooksLikeBootArgs(candidate)) continue;
            *bootArgsPointer = slots[index];
            if (candidateCapture)
                [candidateCapture writeToFile:
                    @(VZTemporaryPath("vz-boot-args-candidates.bin")) atomically:NO];
            dprintf(STDERR_FILENO,
                "[GuestPolicy] validated boot_args=%p through global=%p\n",
                (void *)targets[index], (void *)slots[index]);
            return YES;
        }
        dprintf(STDERR_FILENO,
            "[GuestPolicy] boot_args fallback examined %lu %s pointers\n",
            (unsigned long)targetCount,
            candidateClass == 0 ? "external" : "kernel-data");
    }
    if (candidateCapture)
        [candidateCapture writeToFile:@(VZTemporaryPath("vz-boot-args-candidates.bin"))
                            atomically:NO];
    return YES;
}

static BOOL FindPolicyGlobals(VZGDBRemote *remote, uint64_t start,
                              uint64_t size, uint64_t *bootArgsPointer,
                              uint64_t *csrCheck, uint64_t *csrConfig,
                              NSError **error)
{
    static const uint32_t pePrefix[] = {
        0xaa0203e3, 0xaa0103e2, 0xaa0003e1,
    };
    static const uint32_t csrCheckTail[] = {
        0x321d012a, 0x5280022b, 0x6a0b011f,
        0x1a8a0128, 0x6a28001f, 0x1a9f07e0, 0xd65f03c0,
    };
    const NSUInteger chunkSize = 256 * 1024;
    const NSUInteger overlap = 64;
    size = MIN(size, UINT64_C(32) * 1024 * 1024);
    BOOL captureKernelText = [[NSFileManager defaultManager]
        fileExistsAtPath:@(VZTemporaryPath("vz-dump-guest-kernel"))];
    NSMutableData *kernelText = captureKernelText
        ? [NSMutableData dataWithLength:(NSUInteger)size] : nil;
    for (uint64_t offset = 0; offset < size &&
         (!*bootArgsPointer || !*csrCheck);) {
        NSUInteger length = (NSUInteger)MIN((uint64_t)chunkSize,
                                             size - offset);
        NSData *data = RemoteRead(remote, start + offset, length, error);
        if (!data) return NO;
        if (kernelText)
            [kernelText replaceBytesInRange:NSMakeRange((NSUInteger)offset,
                length) withBytes:data.bytes length:length];
        const uint8_t *bytes = data.bytes;
        for (NSUInteger position = 0; position + 40 <= data.length;
             position += 4) {
            uint64_t pc = start + offset + position;
            const uint32_t *instruction = (const void *)(bytes + position);
            if (!*bootArgsPointer &&
                !memcmp(instruction, pePrefix, sizeof(pePrefix))) {
                uint32_t adrp = instruction[3], add = instruction[4];
                uint32_t load = instruction[5], commandLine = instruction[6];
                if ((adrp & 0x9f00001f) == 0x90000008 &&
                    (add & 0xffc003ff) == 0x91000108 &&
                    (load & 0xffc003ff) == 0xf9400108 &&
                    commandLine == 0x9101b100) {
                    uint64_t addValue = ((add >> 10) & 0xfff) <<
                        ((add & (1 << 22)) ? 12 : 0);
                    uint64_t loadValue = ((load >> 10) & 0xfff) * 8;
                    *bootArgsPointer = DecodeADRP(pc + 12, adrp) +
                                       addValue + loadValue;
                }
            }
            // Match the complete csr_check() leaf function, including its
            // CSR_ALLOW_KERNEL_DEBUGGER synthesis and final EPERM test. This
            // identifies both the enforcement entry point and csr_config;
            // matching an isolated load produced false positives.
            // https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.81.2/bsd/kern/kern_csr.c
            if (!*csrCheck &&
                (instruction[2] & 0xff8003ff) == 0x12000109 &&
                !memcmp(instruction + 3, csrCheckTail,
                        sizeof(csrCheckTail))) {
                uint32_t adrp = instruction[0], load = instruction[1];
                if ((adrp & 0x9f00001f) == 0x90000008 &&
                    (load & 0xffc003ff) == 0xb9400108) {
                    uint64_t loadValue = ((load >> 10) & 0xfff) * 4;
                    *csrCheck = pc;
                    *csrConfig = DecodeADRP(pc, adrp) + loadValue;
                }
            }
        }
        if (length <= overlap) break;
        offset += length - overlap;
    }
    if (kernelText) {
        [kernelText writeToFile:@(VZTemporaryPath("vz-guest-kernel-text.bin"))
                       atomically:NO];
        dprintf(STDERR_FILENO,
            "[GuestPolicy] captured kernel text start=0x%llx size=0x%llx\n",
            start, size);
    }
    return YES;
}

static BOOL ApplyCSRRuntimePolicy(VZGDBRemote *remote, uint64_t csrCheck,
                                  uint64_t csrConfig,
                                  NSError **error)
{
    // csr_config can be rewritten during early startup as signed LocalPolicy
    // is imported and the late-read-only region is finalized. Break on the
    // stable csr_check() ABI and retain the breakpoint until our value survives
    // from one real CSR check to the next. This is event-driven: there is no
    // fixed boot delay and no persistent LocalPolicy edit.
    // https://github.com/apple-oss-distributions/xnu/blob/xnu-8792.81.2/bsd/kern/kern_csr.c
    NSData *reply = RemoteRequest(remote, [NSString stringWithFormat:
        @"Z0,%llx,4", csrCheck], error);
    if (![reply isEqualToData:[@"OK" dataUsingEncoding:
                               NSASCIIStringEncoding]]) {
        if (error && !*error) *error = PolicyError(18,
            @"The guest SIP initialization breakpoint was rejected.");
        return NO;
    }
    struct timeval timeout = { .tv_sec = 60, .tv_usec = 0 };
    setsockopt(remote->descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
               sizeof(timeout));
    // Production XNU starts with CSR_DISABLE_FLAGS (0x7f), then
    // csr_bootstrap() removes CSR_ALLOW_APPLE_INTERNAL. Match that final
    // enforcement value rather than accidentally opting a release kernel into
    // Apple-internal behavior.
    uint32_t disabled = 0x6f;
    BOOL observedStable = NO;
    NSUInteger hit = 0;
    for (; hit < 16; ++hit) {
        NSData *stop = RemoteRequest(remote, @"c", error);
        uint64_t stopPC = stop ? ParseProgramCounter(stop) : 0;
        if (stopPC != csrCheck && stopPC != csrCheck + 4) break;
        NSData *currentData = RemoteRead(remote, csrConfig,
                                         sizeof(disabled), error);
        uint32_t current = 0;
        if (currentData.length == sizeof(current))
            memcpy(&current, currentData.bytes, sizeof(current));
        if (current == disabled) {
            observedStable = YES;
            break;
        }
        if (!RemoteWrite(remote, csrConfig,
                [NSData dataWithBytes:&disabled length:sizeof(disabled)],
                error))
            break;
    }
    NSError *ignored = nil;
    RemoteRequest(remote, [NSString stringWithFormat:@"z0,%llx,4", csrCheck],
                  &ignored);
    if (!observedStable) {
        if (error && !*error) *error = PolicyError(20,
            @"The guest SIP policy did not stabilize during startup.");
        return NO;
    }
    dprintf(STDERR_FILENO,
        "[GuestPolicy] applied stable SIP policy csr-check=%p csr=%p "
        "hits=%lu\n", (void *)csrCheck, (void *)csrConfig,
        (unsigned long)(hit + 1));
    return YES;
}

static BOOL PatchRuntimePolicy(VZGDBRemote *remote, uint64_t pc,
                               NSError **error)
{
    uint64_t kernel = 0;
    VZKernelSegments segments = {0};
    if (!FindKernel(remote, pc, &kernel, &segments, error)) return NO;
    uint64_t slide = kernel - segments.textAddress;
    uint64_t bootArgsPointer = 0, csrCheck = 0, csrConfig = 0;
    if (!FindPolicyGlobals(remote, segments.executeAddress + slide,
            segments.executeSize, &bootArgsPointer, &csrCheck, &csrConfig,
            error))
        return NO;
    if (!bootArgsPointer && !FindBootArgsPointerByData(remote, &segments,
            slide, &bootArgsPointer, error))
        return NO;
    if (!bootArgsPointer) {
        if (error) *error = PolicyError(13,
            @"This guest kernel does not expose the supported runtime policy structures.");
        return NO;
    }
    NSData *pointerData = RemoteRead(remote, bootArgsPointer, 8, error);
    if (!pointerData) return NO;
    uint64_t bootArgs = 0;
    memcpy(&bootArgs, pointerData.bytes, sizeof(bootArgs));

    uint64_t commandAddress = bootArgs + 0x6c;
    NSData *commandData = RemoteRead(remote, commandAddress, 1024, error);
    if (!commandData) return NO;
    NSUInteger commandLength = strnlen(commandData.bytes, commandData.length);
    NSString *command = [[[NSString alloc] initWithBytes:commandData.bytes
        length:commandLength encoding:NSUTF8StringEncoding] autorelease] ?: @"";
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *token in [command componentsSeparatedByCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (!token.length || [token isEqualToString:@"-arm64e_preview_abi"] ||
            [token hasPrefix:@"amfi_get_out_of_my_way="] ||
            [token hasPrefix:@"ipc_control_port_options="])
            continue;
        [tokens addObject:token];
    }
    [tokens addObject:@"-arm64e_preview_abi"];
    NSData *updated = [[tokens componentsJoinedByString:@" "]
        dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *terminated = [NSMutableData dataWithData:updated];
    uint8_t zero = 0;
    [terminated appendBytes:&zero length:1];
    if (terminated.length >= 1024) {
        if (error) *error = PolicyError(14,
            @"The guest boot argument buffer is full.");
        return NO;
    }
    if (!csrCheck || !csrConfig) {
        if (error) *error = PolicyError(17,
            @"This guest kernel does not expose the supported SIP policy ABI.");
        return NO;
    }
    if (!RemoteWrite(remote, commandAddress, terminated, error) ||
        !ApplyCSRRuntimePolicy(remote, csrCheck, csrConfig, error))
        return NO;
    dprintf(STDERR_FILENO,
        "[GuestPolicy] kernel=0x%llx boot-args=0x%llx csr=0x%llx\n",
        kernel, bootArgs, csrConfig);
    return YES;
}

static BOOL ApplyRuntimePolicy(NSError **error)
{
    dprintf(STDERR_FILENO, "[GuestPolicy] connecting to early-boot endpoint\n");
    // Connecting immediately after VZ's start completion can stop either the
    // last iBoot instructions or the first kernel instructions. Detach from a
    // low-address stop (which resumes the guest), then reconnect until the
    // kernel is mapped. This avoids a fixed boot delay across guest releases.
    for (NSUInteger attempt = 0; attempt < 40; ++attempt) {
        VZGDBRemote remote;
        NSError *connectionError = nil;
        if (!RemoteConnect(&remote, &connectionError)) {
            if (error) *error = connectionError;
            return NO;
        }
        RemoteRequest(&remote, @"qSupported", &connectionError);
        NSData *stop = RemoteRequest(&remote, @"?", &connectionError);
        uint64_t pc = stop ? ParseProgramCounter(stop) : 0;
        dprintf(STDERR_FILENO,
                "[GuestPolicy] early-boot stop=%lu pc=0x%llx\n",
                (unsigned long)attempt, pc);
        if (!pc) {
            RemoteDetach(&remote);
            if (error) *error = connectionError ?: PolicyError(15,
                @"The guest debug stop did not contain a program counter.");
            return NO;
        }
        if (pc < UINT64_C(0xffff000000000000)) {
            RemoteDetach(&remote);
            usleep(100 * 1000);
            continue;
        }
        BOOL success = PatchRuntimePolicy(&remote, pc, error);
        RemoteDetach(&remote);
        return success;
    }
    if (error) *error = PolicyError(16,
        @"The guest kernel did not become available during early boot.");
    return NO;
}

BOOL VZGuestRuntimePolicyConfigureDebugStub(id configuration, BOOL enabled)
{
    if (!enabled) return YES;
    Class cls = objc_getClass("_VZGDBDebugStubConfiguration");
    SEL setter = S("_setDebugStub:");
    if (!cls || ![configuration respondsToSelector:setter]) return NO;
    id stub = ((id(*)(id, SEL))objc_msgSend)(cls, S("new"));
    ((void(*)(id, SEL, uint16_t))objc_msgSend)(stub, S("setPort:"),
                                               kDebugStubPort);
    // This is an implementation detail, not a remote-debugging feature.
    ((void(*)(id, SEL, BOOL))objc_msgSend)(stub,
        S("setListensOnAllNetworkInterfaces:"), NO);
    ((void(*)(id, SEL, id))objc_msgSend)(configuration, setter, stub);
    [stub release];
    return YES;
}

void VZGuestRuntimePolicyConfigureStartOptions(id startOptions)
{
    SEL selector = S("_setStopInIBootStage1:");
    if ([startOptions respondsToSelector:selector])
        ((void(*)(id, SEL, BOOL))objc_msgSend)(startOptions, selector, YES);
}

void VZGuestRuntimePolicyApplyAsync(
    void (^completion)(BOOL success, NSError *error))
{
    dprintf(STDERR_FILENO, "[GuestPolicy] scheduling runtime update\n");
    void (^copiedCompletion)(BOOL, NSError *) = [completion copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL success = ApplyRuntimePolicy(&error);
        dprintf(STDERR_FILENO,
                "[GuestPolicy] runtime worker completed success=%d error=%s\n",
                success, error.localizedDescription.UTF8String ?: "none");
        dispatch_async(dispatch_get_main_queue(), ^{
            copiedCompletion(success, error);
            [copiedCompletion release];
        });
    });
}

#endif
