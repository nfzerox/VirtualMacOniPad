#include "VZPaths.h"
// Compatibility hook loaded into Ventura's iOS-stamped
// com.apple.Virtualization.Installation helper.
//
// A macOS XPC service normally receives its listener from launchd through
// xpc_main(). The iPad host starts this helper directly, so publish an
// anonymous listener endpoint which VZHostCompat can recover through the
// child's task port. This is the same rendezvous already proven for the VMM.
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <ptrauth.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

#define DEFAULT_INSTALLATION_EP_FILE VZTemporaryPath("installation_ep.txt")
#define XPC_ENDPOINT_PORT_OFF 0x18

typedef void *xpc_object_t;
typedef void *xpc_connection_t;
typedef void *xpc_endpoint_t;

extern void xpc_main(void (*handler)(xpc_object_t));
extern xpc_connection_t xpc_connection_create(
    const char *name, dispatch_queue_t targetQueue);
extern void xpc_connection_set_event_handler(
    xpc_connection_t connection, void (^handler)(xpc_object_t));
extern void xpc_connection_resume(xpc_connection_t connection);
extern xpc_endpoint_t xpc_endpoint_create(xpc_connection_t connection);
extern const void *xpc_get_type(xpc_object_t object);
extern char *xpc_copy_description(xpc_object_t object);
extern int sandbox_init_with_parameters(
    const char *profile, uint64_t flags,
    const char *const parameters[], char **errorbuf);
extern char _xpc_type_connection[];
extern size_t confstr(int name, char *buffer, size_t length);

static void installation_log(const char *message)
{
    FILE *file = fopen(VZTemporaryPath("installationhook.log"), "a");
    if (!file)
        return;
    fchmod(fileno(file), VZLogMode);
    fprintf(file, "[installationhook] pid=%d %s\n", getpid(), message);
    fclose(file);
}

static uintptr_t installation_decode_adrp(uint32_t instruction, uintptr_t pc)
{
    int64_t immediate =
        ((instruction >> 29) & 0x3) |
        (((instruction >> 5) & 0x7ffff) << 2);
    if (immediate & (1 << 20))
        immediate -= 1 << 21;
    return (pc & ~(uintptr_t)0xfff) + immediate * 4096;
}

static void *installation_repair_crypto_error_implementation(
    void *(*getter)(void))
{
    void *implementation = getter();
    if (implementation)
        return implementation;

    // Ventura 13.2.1's ERR_get_implementation is a tiny wrapper around an
    // internal initializer. Decode its own global-slot load and the default
    // implementation reference in that initializer instead of baking in an
    // ASLR address. Refuse to patch if this exact instruction shape changes.
    uint32_t *code = (uint32_t *)ptrauth_strip(
        (void *)getter, ptrauth_key_function_pointer);
    uint32_t slotADRP = code[4];       // getter + 0x10
    uint32_t slotLDR = code[5];        // getter + 0x14
    uint32_t defaultADRP = code[26];   // getter + 0x68
    uint32_t defaultADD = code[27];    // getter + 0x6c
    if ((slotADRP & 0x9f000000) != 0x90000000 ||
        (slotLDR & 0xffc00000) != 0xf9400000 ||
        (defaultADRP & 0x9f000000) != 0x90000000 ||
        (defaultADD & 0xffc00000) != 0x91000000)
        return NULL;

    uintptr_t slotPage = installation_decode_adrp(
        slotADRP, (uintptr_t)&code[4]);
    uintptr_t defaultPage = installation_decode_adrp(
        defaultADRP, (uintptr_t)&code[26]);
    void **slot = (void **)(slotPage + (((slotLDR >> 10) & 0xfff) << 3));
    void *defaultImplementation =
        (void *)(defaultPage + ((defaultADD >> 10) & 0xfff));
    *slot = defaultImplementation;
    return getter();
}

__attribute__((constructor)) static void installation_hook_init(void)
{
    installation_log("loaded");
}

static void installation_xpc_main(void (*handler)(xpc_object_t))
{
    // MobileDevice's constructor starts its booted-device registration worker
    // while the restore-image request can concurrently enter
    // AMRestorableBuildCreate.  On macOS libcrypto is already process-global;
    // here it is private to this freshly launched helper, and the two threads
    // can both reach ERR_get_state before its implementation table exists.
    // Initialize that table before MobileDevice is allowed to load and create
    // its worker threads.
    void *crypto = dlopen("@loader_path/crypto.dylib",
                          RTLD_NOW | RTLD_GLOBAL);
    if (!crypto) {
        installation_log(dlerror() ?: "failed to preload crypto.dylib");
    } else {
        void *(*get_error_implementation)(void) =
            dlsym(crypto, "ERR_get_implementation");
        if (get_error_implementation) {
            void *implementation =
                installation_repair_crypto_error_implementation(
                    get_error_implementation);
            char message[128];
            snprintf(message, sizeof(message),
                     "preinitialized libcrypto error state: %p",
                     implementation);
            installation_log(message);
        } else {
            installation_log("ERR_get_implementation is unavailable");
        }
    }

    installation_log("creating anonymous XPC listener");
    xpc_connection_t listener =
        xpc_connection_create(NULL, dispatch_get_main_queue());
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) == (const void *)_xpc_type_connection) {
            installation_log("accepted host peer");
            handler(event);
        } else {
            char *description = xpc_copy_description(event);
            FILE *file = fopen(VZTemporaryPath("installationhook.log"), "a");
            if (file) {
                fprintf(file, "[installationhook] listener event: %s\n",
                        description ?: "(unknown)");
                fclose(file);
            }
            free(description);
        }
    });
    xpc_connection_resume(listener);

    xpc_endpoint_t endpoint = xpc_endpoint_create(listener);
    uint32_t port = *(uint32_t *)((char *)endpoint + XPC_ENDPOINT_PORT_OFF);
    const char *endpointFile = getenv("VZ_INSTALLATION_ENDPOINT_FILE");
    if (!endpointFile || !endpointFile[0])
        endpointFile = DEFAULT_INSTALLATION_EP_FILE;
    FILE *file = fopen(endpointFile, "w");
    if (!file) {
        installation_log("failed to publish endpoint");
        _exit(70);
    }
    fprintf(file, "0x%x\n", port);
    fclose(file);
    installation_log("published endpoint");
    dispatch_main();
}

static int installation_sandbox_init_with_parameters(
    const char *profile, uint64_t flags,
    const char *const parameters[], char **errorbuf)
{
    (void)profile;
    (void)flags;
    (void)parameters;
    if (errorbuf)
        *errorbuf = NULL;
    installation_log("bypassed macOS runtime sandbox profile");
    return 0;
}

static size_t installation_confstr(int name, char *buffer, size_t length)
{
    // iPadOS returns EIO for Darwin's non-containerized per-user cache and
    // temp selectors. The Ventura helper treats that as fatal before it can
    // accept its XPC peer.
    if (name == 65537 || name == 65538) {
        const char *path = VZTemporaryPath("");
        size_t required = strlen(path) + 1;
        if (buffer && length) {
            size_t copied = required < length ? required : length;
            memcpy(buffer, path, copied);
            buffer[length - 1] = '\0';
        }
        installation_log("supplied Darwin user cache/temp directory");
        return required;
    }
    static size_t (*realConfstr)(int, char *, size_t);
    if (!realConfstr)
        realConfstr = dlsym(RTLD_NEXT, "confstr");
    return realConfstr ? realConfstr(name, buffer, length) : 0;
}

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} installation_xpc_main_interpose
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)&installation_xpc_main,
        (const void *)&xpc_main,
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} installation_sandbox_interpose
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)&installation_sandbox_init_with_parameters,
        (const void *)&sandbox_init_with_parameters,
    };

__attribute__((used)) static struct {
    const void *replacement;
    const void *replacee;
} installation_confstr_interpose
    __attribute__((section("__DATA,__interpose"))) = {
        (const void *)&installation_confstr,
        (const void *)&confstr,
    };
