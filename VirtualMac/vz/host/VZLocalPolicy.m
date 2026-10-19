#include "VZPaths.h"
#import "VZLocalPolicy.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#include <fcntl.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString * const VZLocalPolicyErrorDomain = @"VirtualMacLocalPolicy";
enum { kBlockSize = 4096 };
static NSString * const kPolicyBackupDirectory = @"GuestTools";
static NSString * const kPolicyBackupFile = @"OriginalLocalPolicy.bin";
static NSString * const kPolicyMetadataFile = @"LocalPolicy.plist";

static void LocalPolicyLog(NSString *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:arguments];
    va_end(arguments);
    int descriptor = open(VZTemporaryPath("VirtualMac.log"),
                          O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (descriptor >= 0) {
        dprintf(descriptor, "[GuestTools] %s\n", message.UTF8String);
        close(descriptor);
    }
}

// SEC1 P-384 key embedded in Ventura 13.2.1 libbootpolicy.dylib as
// `_hacktivation_oik`. The certificate digest below prevents this build-specific
// development key from signing an unrelated LocalPolicy representation.
static const uint8_t kHacktivationPrivateKey[] = {
    0x30,0x81,0xa4,0x02,0x01,0x01,0x04,0x30,0xe2,0xa4,0xe0,0xe6,0x21,0x41,0x06,0xc1,
    0x66,0x37,0xda,0x2d,0x4e,0x38,0x41,0xfc,0x81,0xcf,0xd9,0xca,0x3c,0x9e,0x20,0x16,
    0x04,0xc7,0xbc,0x22,0x23,0xec,0xef,0x9e,0x12,0xa4,0x63,0x37,0x2e,0x0c,0x95,0x8c,
    0xe6,0x8f,0x39,0x97,0x65,0x68,0xfc,0xae,0xa0,0x07,0x06,0x05,0x2b,0x81,0x04,0x00,
    0x22,0xa1,0x64,0x03,0x62,0x00,0x04,0x5f,0x73,0x89,0xa2,0x5f,0xf0,0x6b,0x97,0x25,
    0xa6,0xeb,0xbc,0xbf,0x64,0x47,0x70,0x61,0x29,0x1f,0x0a,0x9b,0xa5,0xfe,0xc6,0x5e,
    0xfc,0xe8,0x65,0xf9,0x75,0x10,0x61,0x7b,0xc4,0x7e,0x72,0xf0,0xdc,0x82,0xa9,0xa1,
    0x8a,0xa8,0x8a,0x43,0x7c,0x1d,0x46,0x47,0x7e,0x3d,0xea,0x30,0x55,0xda,0xf7,0x62,
    0xad,0x18,0x55,0x3b,0xab,0x6e,0xd7,0xd2,0x79,0xe8,0x8c,0x6e,0x82,0x8e,0xa5,0xbf,
    0x21,0x7d,0xc0,0xef,0x49,0x66,0x6e,0x0a,0xe9,0x3f,0xf8,0xe2,0x4c,0xef,0xe1,0xa6,
    0xdf,0xec,0x88,0x7d,0x93,0x29,0x40,
};

static const uint8_t kHacktivationCertificateChainSHA256[CC_SHA256_DIGEST_LENGTH] = {
    0x7d,0x27,0x8c,0x50,0x0a,0x4f,0x32,0x8a,0x52,0x90,0x87,0x95,0x7f,0x73,0xd1,0xef,
    0x99,0xf0,0x89,0x05,0x49,0xd7,0xda,0x94,0x5a,0xeb,0x53,0xb0,0x1f,0x28,0x7d,0x50,
};

typedef struct {
    const uint8_t *tlv;
    size_t headerLength;
    size_t contentLength;
    uint8_t tag;
} DERTLV;

static BOOL DERRead(const uint8_t *bytes, size_t available, DERTLV *item)
{
    if (available < 2) return NO;
    size_t header = 2;
    size_t length = bytes[1];
    if (length & 0x80) {
        size_t count = length & 0x7f;
        if (!count || count > sizeof(size_t) || available < 2 + count)
            return NO;
        length = 0;
        for (size_t index = 0; index < count; ++index)
            length = (length << 8) | bytes[2 + index];
        header += count;
    }
    if (length > available - header) return NO;
    item->tlv = bytes;
    item->headerLength = header;
    item->contentLength = length;
    item->tag = bytes[0];
    return YES;
}

static BOOL DERReadAnyTag(const uint8_t *bytes, size_t available, DERTLV *item)
{
    if (available < 2) return NO;
    size_t tagLength = 1;
    if ((bytes[0] & 0x1f) == 0x1f) {
        while (tagLength < available && (bytes[tagLength++] & 0x80)) {}
        if (tagLength >= available) return NO;
    }
    size_t lengthOffset = tagLength;
    size_t header = lengthOffset + 1;
    size_t length = bytes[lengthOffset];
    if (length & 0x80) {
        size_t count = length & 0x7f;
        if (!count || count > sizeof(size_t) ||
            available < lengthOffset + 1 + count)
            return NO;
        length = 0;
        for (size_t index = 0; index < count; ++index)
            length = (length << 8) | bytes[lengthOffset + 1 + index];
        header += count;
    }
    if (length > available - header) return NO;
    item->tlv = bytes;
    item->headerLength = header;
    item->contentLength = length;
    item->tag = bytes[0];
    return YES;
}

static BOOL DERSetContentLength(DERTLV item, size_t length)
{
    size_t tagLength = 1;
    if ((item.tlv[0] & 0x1f) == 0x1f)
        while (tagLength < item.headerLength &&
               (item.tlv[tagLength++] & 0x80)) {}
    if (tagLength >= item.headerLength) return NO;
    uint8_t *lengthBytes = (uint8_t *)item.tlv + tagLength;
    if (!(lengthBytes[0] & 0x80)) {
        if (length >= 0x80) return NO;
        lengthBytes[0] = (uint8_t)length;
        return YES;
    }
    size_t count = lengthBytes[0] & 0x7f;
    if (!count || tagLength + 1 + count != item.headerLength ||
        (count < sizeof(size_t) && length >= ((size_t)1 << (count * 8))))
        return NO;
    for (size_t index = 0; index < count; ++index) {
        lengthBytes[count - index] = (uint8_t)(length & 0xff);
        length >>= 8;
    }
    return length == 0;
}

static const uint8_t *DERContent(DERTLV item)
{
    return item.tlv + item.headerLength;
}

static BOOL DERNext(const uint8_t **cursor, size_t *remaining, DERTLV *item)
{
    if (!DERRead(*cursor, *remaining, item)) return NO;
    size_t total = item->headerLength + item->contentLength;
    *cursor += total;
    *remaining -= total;
    return YES;
}

static BOOL BytesEqual(DERTLV item, uint8_t tag, const char *value)
{
    size_t length = strlen(value);
    return item.tag == tag && item.contentLength == length &&
        !memcmp(DERContent(item), value, length);
}

static BOOL PolicyContainsNamedProperty(DERTLV signedBody,
                                        const char name[4])
{
    const uint8_t *bytes = signedBody.tlv;
    size_t length = signedBody.headerLength + signedBody.contentLength;
    NSUInteger matches = 0;
    for (size_t offset = 0; offset + 6 <= length; ++offset) {
        if (bytes[offset] == 0x16 && bytes[offset + 1] == 4 &&
            !memcmp(bytes + offset + 2, name, 4))
            ++matches;
    }
    return matches == 1;
}

typedef struct {
    DERTLV image;
    DERTLV manifestTag;
    DERTLV manifest;
    DERTLV signedBody;
    DERTLV signature;
    DERTLV certificates;
} LocalPolicyLayout;

static BOOL ParseLocalPolicy(const uint8_t *bytes, size_t available,
                             LocalPolicyLayout *layout)
{
    DERTLV image;
    if (!DERRead(bytes, available, &image) || image.tag != 0x30)
        return NO;
    const uint8_t *cursor = DERContent(image);
    size_t remaining = image.contentLength;
    DERTLV name, payload, manifestTag;
    if (!DERNext(&cursor, &remaining, &name) ||
        !BytesEqual(name, 0x16, "IMG4") ||
        !DERNext(&cursor, &remaining, &payload) || payload.tag != 0x30)
        return NO;
    const uint8_t *payloadCursor = DERContent(payload);
    size_t payloadRemaining = payload.contentLength;
    DERTLV payloadName, payloadType;
    if (!DERNext(&payloadCursor, &payloadRemaining, &payloadName) ||
        !BytesEqual(payloadName, 0x16, "IM4P") ||
        !DERNext(&payloadCursor, &payloadRemaining, &payloadType) ||
        !BytesEqual(payloadType, 0x16, "lpol") ||
        !DERNext(&cursor, &remaining, &manifestTag) ||
        manifestTag.tag != 0xa0 || remaining)
        return NO;
    const uint8_t *manifestCursor = DERContent(manifestTag);
    size_t manifestRemaining = manifestTag.contentLength;
    DERTLV manifest;
    if (!DERNext(&manifestCursor, &manifestRemaining, &manifest) ||
        manifest.tag != 0x30 || manifestRemaining)
        return NO;
    const uint8_t *entry = DERContent(manifest);
    size_t entryRemaining = manifest.contentLength;
    DERTLV manifestName, version, signedBody, signature, certificates;
    if (!DERNext(&entry, &entryRemaining, &manifestName) ||
        !BytesEqual(manifestName, 0x16, "IM4M") ||
        !DERNext(&entry, &entryRemaining, &version) || version.tag != 0x02 ||
        !DERNext(&entry, &entryRemaining, &signedBody) || signedBody.tag != 0x31 ||
        !DERNext(&entry, &entryRemaining, &signature) || signature.tag != 0x04 ||
        !DERNext(&entry, &entryRemaining, &certificates) || certificates.tag != 0x30 ||
        entryRemaining)
        return NO;
    layout->image = image;
    layout->manifestTag = manifestTag;
    layout->manifest = manifest;
    layout->signedBody = signedBody;
    layout->signature = signature;
    layout->certificates = certificates;
    return YES;
}

typedef struct {
    DERTLV manbWrapper;
    DERTLV manbSequence;
    DERTLV manbSet;
    DERTLV manpWrapper;
    DERTLV manpSequence;
    DERTLV manpSet;
    const uint8_t *sipStart;
    const uint8_t *sipEnd;
    const uint8_t *insertionPoint;
    NSUInteger sipCount;
} LocalPolicyProperties;

static BOOL ParsePropertyWrapper(DERTLV wrapper, DERTLV *sequence,
                                 DERTLV *name, DERTLV *value)
{
    const uint8_t *cursor = DERContent(wrapper);
    size_t remaining = wrapper.contentLength;
    if (!DERRead(cursor, remaining, sequence) || sequence->tag != 0x30 ||
        sequence->headerLength + sequence->contentLength != remaining)
        return NO;
    cursor = DERContent(*sequence);
    remaining = sequence->contentLength;
    return DERNext(&cursor, &remaining, name) && name->tag == 0x16 &&
        DERNext(&cursor, &remaining, value) && !remaining;
}

static BOOL ParsePolicyProperties(LocalPolicyLayout layout,
                                  LocalPolicyProperties *properties)
{
#define POLICY_PARSE_REQUIRE(condition, stage) do { \
    if (!(condition)) { \
        if (getenv("VZ_LOCAL_POLICY_TRACE")) \
            dprintf(STDERR_FILENO, \
                    "[GuestTools] LocalPolicy property parse stage %d failed\n", \
                    (stage)); \
        return NO; \
    } \
} while (0)
    memset(properties, 0, sizeof(*properties));
    const uint8_t *cursor = DERContent(layout.signedBody);
    size_t remaining = layout.signedBody.contentLength;
    POLICY_PARSE_REQUIRE(DERReadAnyTag(cursor, remaining,
                                      &properties->manbWrapper) &&
        properties->manbWrapper.headerLength +
            properties->manbWrapper.contentLength == remaining, 1);
    DERTLV name;
    POLICY_PARSE_REQUIRE(ParsePropertyWrapper(properties->manbWrapper,
                                              &properties->manbSequence,
                                              &name,
                                              &properties->manbSet) &&
        BytesEqual(name, 0x16, "MANB") && properties->manbSet.tag == 0x31, 2);

    cursor = DERContent(properties->manbSet);
    remaining = properties->manbSet.contentLength;
    while (remaining) {
        DERTLV wrapper, sequence, entryName, value;
        POLICY_PARSE_REQUIRE(DERReadAnyTag(cursor, remaining, &wrapper), 3);
        size_t total = wrapper.headerLength + wrapper.contentLength;
        POLICY_PARSE_REQUIRE(ParsePropertyWrapper(wrapper, &sequence,
                                                  &entryName, &value), 4);
        if (BytesEqual(entryName, 0x16, "MANP")) {
            POLICY_PARSE_REQUIRE(!properties->manpWrapper.tlv &&
                                 value.tag == 0x31, 5);
            properties->manpWrapper = wrapper;
            properties->manpSequence = sequence;
            properties->manpSet = value;
        }
        cursor += total;
        remaining -= total;
    }
    POLICY_PARSE_REQUIRE(properties->manpWrapper.tlv, 6);

    cursor = DERContent(properties->manpSet);
    remaining = properties->manpSet.contentLength;
    properties->insertionPoint = cursor + remaining;
    const uint8_t *previousEnd = NULL;
    const char *expectedSIPNames[] = { "sip0", "sip2", "sip3" };
    while (remaining) {
        DERTLV wrapper, sequence, entryName, value;
        POLICY_PARSE_REQUIRE(DERReadAnyTag(cursor, remaining, &wrapper), 7);
        size_t total = wrapper.headerLength + wrapper.contentLength;
        POLICY_PARSE_REQUIRE(ParsePropertyWrapper(wrapper, &sequence,
                                                  &entryName, &value), 8);
        if (getenv("VZ_LOCAL_POLICY_TRACE"))
            dprintf(STDERR_FILENO,
                    "[GuestTools] LocalPolicy MANP property %.*s tag=0x%x\n",
                    (int)entryName.contentLength, DERContent(entryName),
                    value.tag);
        for (NSUInteger index = 0; index < 3; ++index) {
            if (!BytesEqual(entryName, 0x16, expectedSIPNames[index]))
                continue;
            if (index != properties->sipCount ||
                (previousEnd && previousEnd != cursor))
                POLICY_PARSE_REQUIRE(NO, 9);
            if (!properties->sipStart) properties->sipStart = cursor;
            properties->sipEnd = cursor + total;
            previousEnd = properties->sipEnd;
            ++properties->sipCount;
        }
        cursor += total;
        remaining -= total;
    }
    POLICY_PARSE_REQUIRE(properties->insertionPoint &&
        (properties->sipCount == 0 || properties->sipCount == 3), 10);
#undef POLICY_PARSE_REQUIRE
    return YES;
}

// The DER private tags encode the property fourcc. These three canonical
// entries are what libbootpolicy writes when SIP is disabled. A normal
// SIP-enabled LocalPolicy omits the entries instead of storing zero values.
static const uint8_t kDisabledSIPProperties[] = {
    0xff,0x87,0x9b,0xa5,0xe0,0x30,0x0b,0x30,0x09,0x16,0x04,0x73,
    0x69,0x70,0x30,0x02,0x01,0x7f,0xff,0x87,0x9b,0xa5,0xe0,0x32,
    0x0b,0x30,0x09,0x16,0x04,0x73,0x69,0x70,0x32,0x01,0x01,0xff,
    0xff,0x87,0x9b,0xa5,0xe0,0x33,0x0b,0x30,0x09,0x16,0x04,0x73,
    0x69,0x70,0x33,0x01,0x01,0xff,
};

static BOOL AdjustPolicyLengths(LocalPolicyLayout layout,
                                LocalPolicyProperties properties,
                                NSInteger delta)
{
    DERTLV ancestors[] = {
        layout.image, layout.manifestTag, layout.manifest, layout.signedBody,
        properties.manbWrapper, properties.manbSequence, properties.manbSet,
        properties.manpWrapper, properties.manpSequence, properties.manpSet,
    };
    for (NSUInteger index = 0;
         index < sizeof(ancestors) / sizeof(ancestors[0]); ++index) {
        NSInteger length = (NSInteger)ancestors[index].contentLength + delta;
        if (length < 0 || !DERSetContentLength(ancestors[index],
                                               (size_t)length))
            return NO;
    }
    return YES;
}

static BOOL TransformSIPConfiguration(uint8_t block[kBlockSize], BOOL enabled)
{
    LocalPolicyLayout layout;
    LocalPolicyProperties properties;
    if (!ParseLocalPolicy(block, kBlockSize, &layout) ||
        !ParsePolicyProperties(layout, &properties))
        return NO;
    size_t imageLength = layout.image.headerLength + layout.image.contentLength;
    const size_t delta = sizeof(kDisabledSIPProperties);
    if (enabled) {
        if (!properties.sipCount) return YES;
        size_t removed = (size_t)(properties.sipEnd - properties.sipStart);
        if (removed != delta ||
            !AdjustPolicyLengths(layout, properties, -(NSInteger)delta))
            return NO;
        size_t offset = (size_t)(properties.sipStart - block);
        memmove(block + offset, block + offset + delta,
                imageLength - offset - delta);
        memset(block + imageLength - delta, 0, delta);
        return YES;
    }
    if (properties.sipCount) {
        return !memcmp(properties.sipStart, kDisabledSIPProperties, delta);
    }
    if (imageLength + delta > kBlockSize ||
        !AdjustPolicyLengths(layout, properties, (NSInteger)delta))
        return NO;
    size_t offset = (size_t)(properties.insertionPoint - block);
    memmove(block + offset + delta, block + offset, imageLength - offset);
    memcpy(block + offset, kDisabledSIPProperties, delta);
    return YES;
}

static SecKeyRef CreateSigningKey(void)
{
    // SecKey's EC private external representation is ANSI X9.63 public point
    // followed by the private scalar, not the SEC1 wrapper stored in dyld.
    NSMutableData *data = [NSMutableData dataWithCapacity:145];
    [data appendBytes:kHacktivationPrivateKey + 70 length:97];
    [data appendBytes:kHacktivationPrivateKey + 8 length:48];
    NSDictionary *attributes = @{
        (id)kSecAttrKeyType: (id)kSecAttrKeyTypeECSECPrimeRandom,
        (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPrivate,
        (id)kSecAttrKeySizeInBits: @384,
    };
    return SecKeyCreateWithData((CFDataRef)data,
                                (CFDictionaryRef)attributes, NULL);
}

static SecKeyRef CopyLeafPublicKey(DERTLV certificates)
{
    const uint8_t *cursor = DERContent(certificates);
    size_t remaining = certificates.contentLength;
    DERTLV certificate, leaf = {};
    while (remaining) {
        if (!DERNext(&cursor, &remaining, &certificate) ||
            certificate.tag != 0x30)
            return NULL;
        leaf = certificate;
    }
    if (!leaf.tlv) return NULL;
    NSData *data = [NSData dataWithBytes:leaf.tlv
        length:leaf.headerLength + leaf.contentLength];
    SecCertificateRef object = SecCertificateCreateWithData(NULL,
        (CFDataRef)data);
    SecKeyRef key = object ? SecCertificateCopyKey(object) : NULL;
    if (object) CFRelease(object);
    return key;
}

static BOOL UpdatePolicyInBlock(uint8_t block[kBlockSize], BOOL enabled,
                                NSError **error)
{
    LocalPolicyLayout layout;
    if (!ParseLocalPolicy(block, kBlockSize, &layout)) return NO;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(DERContent(layout.certificates),
              (CC_LONG)layout.certificates.contentLength, digest);
    if (memcmp(digest, kHacktivationCertificateChainSHA256, sizeof(digest)))
        return NO;

    SecKeyRef publicKey = CopyLeafPublicKey(layout.certificates);
    NSData *originalBlock = [NSData dataWithBytes:block length:kBlockSize];
    NSData *originalBody = [NSData dataWithBytes:layout.signedBody.tlv
        length:layout.signedBody.headerLength + layout.signedBody.contentLength];
    NSData *originalSignature = [NSData dataWithBytes:
        DERContent(layout.signature) length:layout.signature.contentLength];
    BOOL originalValid = publicKey && SecKeyVerifySignature(publicKey,
        kSecKeyAlgorithmECDSASignatureMessageX962SHA384,
        (CFDataRef)originalBody, (CFDataRef)originalSignature, NULL);
    if (!originalValid) {
        if (error) *error = [NSError errorWithDomain:VZLocalPolicyErrorDomain
            code:3 userInfo:@{NSLocalizedDescriptionKey:
            @"The Virtual Mac LocalPolicy signature could not be verified."}];
        if (publicKey) CFRelease(publicKey);
        return NO;
    }
    if (!TransformSIPConfiguration(block, enabled) ||
        !ParseLocalPolicy(block, kBlockSize, &layout)) {
        if (error) *error = [NSError errorWithDomain:VZLocalPolicyErrorDomain
            code:4 userInfo:@{NSLocalizedDescriptionKey:
            @"The Virtual Mac LocalPolicy has an unsupported structure."}];
        CFRelease(publicKey);
        return NO;
    }
    NSData *updatedBlock = [NSData dataWithBytes:block length:kBlockSize];
    if ([updatedBlock isEqualToData:originalBlock]) {
        CFRelease(publicKey);
        return YES;
    }
    NSData *updatedBody = [NSData dataWithBytes:layout.signedBody.tlv
        length:layout.signedBody.headerLength + layout.signedBody.contentLength];
    SecKeyRef privateKey = CreateSigningKey();
    if (!privateKey) {
        if (error) *error = [NSError errorWithDomain:VZLocalPolicyErrorDomain
            code:6 userInfo:@{NSLocalizedDescriptionKey:
            @"The Virtual Mac LocalPolicy signing key is unavailable."}];
        CFRelease(publicKey);
        return NO;
    }
    for (NSUInteger attempt = 0; attempt < 4096; ++attempt) {
        CFErrorRef signingError = NULL;
        CFDataRef candidate = SecKeyCreateSignature(privateKey,
            kSecKeyAlgorithmECDSASignatureMessageX962SHA384,
            (CFDataRef)updatedBody, &signingError);
        if (signingError) CFRelease(signingError);
        if (!candidate) continue;
        NSData *signature = (__bridge NSData *)candidate;
        if (signature.length == layout.signature.contentLength &&
            SecKeyVerifySignature(publicKey,
                kSecKeyAlgorithmECDSASignatureMessageX962SHA384,
                (CFDataRef)updatedBody, candidate, NULL)) {
            memcpy((void *)DERContent(layout.signature), signature.bytes,
                   signature.length);
            CFRelease(candidate);
            CFRelease(publicKey);
            CFRelease(privateKey);
            return YES;
        }
        CFRelease(candidate);
    }
    if (error) *error = [NSError errorWithDomain:VZLocalPolicyErrorDomain
        code:5 userInfo:@{NSLocalizedDescriptionKey:
        @"Virtual Mac could not create an equal-size LocalPolicy signature."}];
    CFRelease(publicKey);
    CFRelease(privateKey);
    return NO;
}

static BOOL NormalizePolicyIdentity(uint8_t block[kBlockSize])
{
    LocalPolicyLayout layout;
    if (!TransformSIPConfiguration(block, NO) ||
        !ParseLocalPolicy(block, kBlockSize, &layout))
        return NO;
    memset((void *)DERContent(layout.signature), 0,
           layout.signature.contentLength);
    return YES;
}

static NSString *PolicySupportPath(NSString *bundlePath, NSString *name)
{
    return [[bundlePath stringByAppendingPathComponent:kPolicyBackupDirectory]
        stringByAppendingPathComponent:name];
}

static BOOL SaveOriginalPolicy(NSString *bundlePath,
                               const uint8_t block[kBlockSize], off_t offset,
                               NSError **error)
{
    NSString *backupPath = PolicySupportPath(bundlePath, kPolicyBackupFile);
    NSString *metadataPath = PolicySupportPath(bundlePath, kPolicyMetadataFile);
    BOOL hasBackup = [[NSFileManager defaultManager]
        fileExistsAtPath:backupPath];
    BOOL hasMetadata = [[NSFileManager defaultManager]
        fileExistsAtPath:metadataPath];
    if (hasBackup || hasMetadata)
        return hasBackup && hasMetadata;
    NSString *directory = [backupPath stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
        withIntermediateDirectories:YES attributes:nil error:error])
        return NO;
    NSData *data = [NSData dataWithBytes:block length:kBlockSize];
    if (![data writeToFile:backupPath options:NSDataWritingAtomic error:error])
        return NO;
    NSDictionary *metadata = @{ @"Offset": @((long long)offset), @"Version": @1 };
    NSData *metadataData = [NSPropertyListSerialization
        dataWithPropertyList:metadata format:NSPropertyListBinaryFormat_v1_0
        options:0 error:error];
    if (!metadataData || ![metadataData writeToFile:metadataPath
        options:NSDataWritingAtomic error:error]) {
        [[NSFileManager defaultManager] removeItemAtPath:backupPath error:nil];
        return NO;
    }
    return YES;
}

typedef struct __attribute__((packed)) {
    uint8_t type[16];
    uint8_t unique[16];
    uint64_t firstLBA;
    uint64_t lastLBA;
    uint64_t attributes;
    uint16_t name[36];
} GPTEntry;

static BOOL ReadISCRange(int descriptor, off_t fileSize,
                         off_t *start, off_t *length)
{
    uint8_t sector[512];
    if (pread(descriptor, sector, sizeof(sector), 512) != sizeof(sector) ||
        memcmp(sector, "EFI PART", 8)) return NO;
    uint64_t entriesLBA = *(uint64_t *)(sector + 72);
    uint32_t entryCount = *(uint32_t *)(sector + 80);
    uint32_t entrySize = *(uint32_t *)(sector + 84);
    if (!entryCount || entryCount > 1024 || entrySize < sizeof(GPTEntry) ||
        entrySize > 4096) return NO;
    // Apple_APFS_ISC GUID 69646961-6700-11aa-aa11-00306543ecac, encoded in
    // GPT's mixed-endian on-disk representation.
    static const uint8_t iscType[16] = {
        0x61,0x69,0x64,0x69,0x00,0x67,0xaa,0x11,
        0xaa,0x11,0x00,0x30,0x65,0x43,0xec,0xac,
    };
    NSMutableData *entryData = [NSMutableData dataWithLength:entrySize];
    NSUInteger matches = 0;
    for (uint32_t index = 0; index < entryCount; ++index) {
        off_t offset = (off_t)entriesLBA * 512 + (off_t)index * entrySize;
        if (pread(descriptor, entryData.mutableBytes, entrySize, offset) !=
            (ssize_t)entrySize) return NO;
        GPTEntry *entry = entryData.mutableBytes;
        if (memcmp(entry->type, iscType, sizeof(iscType))) continue;
        if (entry->lastLBA < entry->firstLBA) return NO;
        off_t rangeStart = (off_t)entry->firstLBA * 512;
        off_t rangeLength = (off_t)(entry->lastLBA - entry->firstLBA + 1) * 512;
        if (rangeStart < 0 || rangeLength <= 0 ||
            rangeStart > fileSize || rangeLength > fileSize - rangeStart)
            return NO;
        *start = rangeStart;
        *length = rangeLength;
        ++matches;
    }
    return matches == 1;
}

BOOL VZSetGuestSIPEnabled(NSString *bundlePath, BOOL enabled, NSError **error)
{
    LocalPolicyLog(@"configuring SIP enabled=%d bundle=%@", enabled,
                   bundlePath.lastPathComponent);
    NSString *path = [bundlePath stringByAppendingPathComponent:@"Disk.img"];
    int descriptor = open(path.fileSystemRepresentation, O_RDWR | O_CLOEXEC);
    if (descriptor < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:errno userInfo:nil];
        return NO;
    }
    struct stat info;
    off_t rangeStart = 0, rangeLength = 0;
    BOOL rangeOK = !fstat(descriptor, &info) &&
        ReadISCRange(descriptor, info.st_size, &rangeStart, &rangeLength);
    if (!rangeOK) {
        if (error) *error = [NSError errorWithDomain:VZLocalPolicyErrorDomain
            code:1 userInfo:@{NSLocalizedDescriptionKey:
            @"The Virtual Mac iBoot System Container could not be located."}];
        close(descriptor);
        return NO;
    }

    const size_t chunkSize = 4 * 1024 * 1024;
    NSMutableData *chunk = [NSMutableData dataWithLength:chunkSize];
    uint8_t original[kBlockSize], replacement[kBlockSize];
    off_t matchOffset = -1;
    NSUInteger matches = 0;
    for (off_t relative = 0; relative < rangeLength; relative += chunkSize) {
        size_t request = (size_t)MIN((off_t)chunkSize, rangeLength - relative);
        ssize_t count = pread(descriptor, chunk.mutableBytes, request,
                              rangeStart + relative);
        if (count != (ssize_t)request) break;
        uint8_t *bytes = chunk.mutableBytes;
        for (size_t blockOffset = 0; blockOffset + kBlockSize <= request;
             blockOffset += kBlockSize) {
            LocalPolicyLayout layout;
            if (!ParseLocalPolicy(bytes + blockOffset, kBlockSize, &layout))
                continue;
            // The iBoot System Container also carries a RecoveryOS policy for
            // the same volume group. Its MANP set is explicitly marked `rolp`;
            // bputil and macOS consume the unmarked policy. Never weaken or
            // rewrite RecoveryOS while configuring the macOS guest.
            if (PolicyContainsNamedProperty(layout.signedBody, "rolp")) {
                LocalPolicyLog(@"skipping RecoveryOS policy at 0x%llx",
                    (unsigned long long)(rangeStart + relative + blockOffset));
                continue;
            }
            memcpy(original, bytes + blockOffset, kBlockSize);
            memcpy(replacement, original, kBlockSize);
            NSError *candidateError = nil;
            if (!UpdatePolicyInBlock(replacement, enabled, &candidateError)) {
                LocalPolicyLog(@"candidate at 0x%llx rejected: %@",
                    (unsigned long long)(rangeStart + relative + blockOffset),
                    candidateError.localizedDescription ?: @"not compatible");
                if (candidateError && error) *error = candidateError;
                continue;
            }
            LocalPolicyLog(@"candidate at 0x%llx transformed",
                (unsigned long long)(rangeStart + relative + blockOffset));
            matchOffset = rangeStart + relative + blockOffset;
            ++matches;
        }
    }
    if (matches != 1) {
        LocalPolicyLog(@"SIP update stopped: compatible candidates=%lu",
                       (unsigned long)matches);
        if (error && !*error) *error = [NSError errorWithDomain:
            VZLocalPolicyErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey:
            matches ? @"Multiple Virtual Mac LocalPolicy files were found."
                    : @"The Virtual Mac LocalPolicy could not be located."}];
        close(descriptor);
        return NO;
    }
    if (!SaveOriginalPolicy(bundlePath, original, matchOffset, error)) {
        close(descriptor);
        return NO;
    }
    if (!memcmp(original, replacement, sizeof(original))) {
        close(descriptor);
        LocalPolicyLog(@"LocalPolicy already configured at 0x%llx",
                       (unsigned long long)matchOffset);
        return YES;
    }
    uint8_t current[kBlockSize];
    BOOL result = pread(descriptor, current, sizeof(current), matchOffset) ==
        sizeof(current) && !memcmp(current, original, sizeof(current)) &&
        pwrite(descriptor, replacement, sizeof(replacement), matchOffset) ==
        sizeof(replacement) && fsync(descriptor) == 0 &&
        pread(descriptor, current, sizeof(current), matchOffset) ==
        sizeof(current) && !memcmp(current, replacement, sizeof(current));
    if (!result && error)
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:errno ?: EIO userInfo:nil];
    close(descriptor);
    if (result)
        LocalPolicyLog(@"LocalPolicy updated and verified at 0x%llx",
                       (unsigned long long)matchOffset);
    else
        LocalPolicyLog(@"LocalPolicy write verification failed at 0x%llx",
                       (unsigned long long)matchOffset);
    return result;
}

BOOL VZEnsureGuestSIPDisabled(NSString *bundlePath, NSError **error)
{
    return VZSetGuestSIPEnabled(bundlePath, NO, error);
}

BOOL VZRestoreGuestLocalPolicy(NSString *bundlePath, NSError **error)
{
    NSString *backupPath = PolicySupportPath(bundlePath, kPolicyBackupFile);
    NSString *metadataPath = PolicySupportPath(bundlePath, kPolicyMetadataFile);
    NSData *backup = [NSData dataWithContentsOfFile:backupPath];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
        metadataPath];
    if (!backup && !metadata)
        return YES;
    if (backup.length != kBlockSize ||
        ![metadata[@"Offset"] isKindOfClass:NSNumber.class]) {
        if (error) *error = [NSError errorWithDomain:VZLocalPolicyErrorDomain
            code:7 userInfo:@{NSLocalizedDescriptionKey:
            @"The saved Virtual Mac LocalPolicy is incomplete."}];
        return NO;
    }
    off_t offset = [metadata[@"Offset"] longLongValue];
    NSString *diskPath = [bundlePath stringByAppendingPathComponent:@"Disk.img"];
    int descriptor = open(diskPath.fileSystemRepresentation,
                          O_RDWR | O_CLOEXEC);
    if (descriptor < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:errno userInfo:nil];
        return NO;
    }
    uint8_t current[kBlockSize], original[kBlockSize];
    memcpy(original, backup.bytes, kBlockSize);
    BOOL readOK = offset >= 0 &&
        pread(descriptor, current, sizeof(current), offset) == sizeof(current);
    uint8_t normalizedCurrent[kBlockSize], normalizedOriginal[kBlockSize];
    memcpy(normalizedOriginal, original, kBlockSize);
    if (readOK) memcpy(normalizedCurrent, current, kBlockSize);
    BOOL identityOK = readOK && NormalizePolicyIdentity(normalizedCurrent) &&
        NormalizePolicyIdentity(normalizedOriginal) &&
        !memcmp(normalizedCurrent, normalizedOriginal, kBlockSize);
    if (!identityOK) {
        close(descriptor);
        if (error) *error = [NSError errorWithDomain:VZLocalPolicyErrorDomain
            code:8 userInfo:@{NSLocalizedDescriptionKey:
            @"The saved LocalPolicy does not belong to this Virtual Mac disk."}];
        return NO;
    }
    if (!memcmp(current, original, kBlockSize)) {
        close(descriptor);
        return YES;
    }
    BOOL result = pwrite(descriptor, original, kBlockSize, offset) == kBlockSize &&
        fsync(descriptor) == 0 &&
        pread(descriptor, current, kBlockSize, offset) == kBlockSize &&
        !memcmp(current, original, kBlockSize);
    if (!result && error)
        *error = [NSError errorWithDomain:NSPOSIXErrorDomain
            code:errno ?: EIO userInfo:nil];
    close(descriptor);
    if (result)
        dprintf(STDERR_FILENO,
                "[GuestTools] restored original LocalPolicy at 0x%llx\n",
                (unsigned long long)offset);
    return result;
}
