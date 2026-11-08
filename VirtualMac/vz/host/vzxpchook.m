#include "VZPaths.h"
// Host-side DYLD_INSERT interpose for the iOS-ported VZ host.
//
// [VZVirtualMachine start] does xpc_connection_create("com.apple.Virtualization.
// VirtualMachine", q). On rootless iOS that name resolves to nothing, and a launchd
// MachServices daemon for it can't reach the system domain (it falls to user/501 — see
// the vmm-xpc-service notes). So instead of launchd, we spawn the VMM ourselves and
// rendezvous over an anonymous xpc endpoint (validated primitive: vz/development/probes/epprobe.m):
//   - create an anonymous listener L (no launchd check-in needed) on a private queue
//   - E = xpc_endpoint_create(L); the backing mach send-right is at E+0x18
//   - posix_spawn the VMM .xpc binary SUSPENDED
//   - task_for_pid(child) + mach_port_insert_right(L's port, COPY_SEND) under a known
//     name (passed in env VMM_EP_PORT); resume the child
//   - the child's vmmhook rebuilds the endpoint from that port and connects back; L's
//     handler captures the peer P, which we return as the result of xpc_connection_create
//
// Build: clang -dynamiclib -arch arm64e -miphoneos-version-min=16.0
//          -Wl,-undefined,dynamic_lookup vzxpchook.m -o vzxpchook.dylib ; ldid -S<ent>
// Use:   DYLD_INSERT_LIBRARIES=/var/root/vzxpchook.ios <host>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <string.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <ptrauth.h>
#include <pthread.h>
#include <sys/wait.h>
#include <time.h>
#include <Block.h>

typedef void *xo_t;
extern xo_t  xpc_connection_create(const char *name, dispatch_queue_t targetq);
extern xo_t  xpc_endpoint_create(xo_t connection);
extern xo_t  xpc_connection_create_from_endpoint(xo_t endpoint);
extern void  xpc_connection_set_event_handler(xo_t, void (^)(xo_t));
extern void  xpc_connection_resume(xo_t);
extern void  xpc_connection_send_message(xo_t, xo_t);
extern void  xpc_connection_send_message_with_reply(
    xo_t, xo_t, dispatch_queue_t, void (^)(xo_t));
extern xo_t xpc_retain(xo_t);
extern void xpc_release(xo_t);
extern const char *xpc_dictionary_get_string(xo_t, const char *);
extern xo_t xpc_dictionary_get_value(xo_t, const char *);
extern uint64_t xpc_dictionary_get_uint64(xo_t, const char *);
extern size_t xpc_array_get_count(xo_t);
extern const void *xpc_data_get_bytes_ptr(xo_t);
extern size_t xpc_data_get_length(xo_t);
extern void xpc_dictionary_set_uint64(xo_t, const char *, uint64_t);
extern xo_t xpc_array_get_value(xo_t, size_t);
extern char *xpc_copy_description(xo_t);
extern mach_port_t xpc_mach_send_get_right(xo_t);
extern void *xpc_get_type(xo_t);
extern char _xpc_type_dictionary[];
extern char _xpc_type_mach_send[];
extern char **environ;

#define VMM_NAME "com.apple.Virtualization.VirtualMachine"
#define DEFAULT_VMM_BIN VZRuntimePath("payload/VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine")
#define INSTALLATION_NAME "com.apple.Virtualization.Installation"
#define DEFAULT_INSTALLATION_BIN VZRuntimePath("payload/Installation.xpc/Contents/MacOS/com.apple.Virtualization.Installation")
#define EP_PORT_OFF  0x18
#define DEFAULT_EP_FILE VZTemporaryPath("vmm_ep.txt")
#define DEFAULT_INSTALLATION_EP_FILE VZTemporaryPath("installation_ep.txt")

static volatile int gVMMStarted;
static xo_t gPendingFramebufferConnection;
static xo_t gPendingFramebufferMessage;
static xo_t gPendingFrameUpdate;
static void (^gPendingFrameHandler)(xo_t);
static dispatch_queue_t gVZConnectionQueue;
static uint64_t gHostEventCount;
static uint64_t gInputSendCount;
static uint64_t gFrameAckCount;
static uint64_t gSurfaceLookupCount;
static bool gDebugLogging;

static uint64_t diagnostic_sequence(uint64_t *counter, uint64_t limit) {
    if (gDebugLogging)
        return __atomic_add_fetch(counter, 1, __ATOMIC_RELAXED);
    uint64_t current = __atomic_load_n(counter, __ATOMIC_RELAXED);
    while (current < limit) {
        uint64_t next = current + 1;
        if (__atomic_compare_exchange_n(
                counter, &current, next, false,
                __ATOMIC_RELAXED, __ATOMIC_RELAXED))
            return next;
    }
    return 0;
}
// A launchd-backed XPC service is a single listener process.  Virtualization
// opens several peer connections to that listener during one installation;
// spawning a fresh helper for every xpc_connection_create call split the DFU
// state across unrelated MobileDevice instances.  Preserve one reconstructed
// listener endpoint and create as many peer connections from it as VZ asks for.
static pthread_mutex_t gInstallationLock = PTHREAD_MUTEX_INITIALIZER;
static xo_t gInstallationEndpoint;
static xo_t gInstallationConnections[16];
static size_t gInstallationConnectionCount;
static pid_t gInstallationPID;

static const char *session_file(const char *environmentName,
                                const char *defaultPath,
                                char storage[PATH_MAX]) {
    const char *configured = getenv(environmentName);
    const char *slash = strrchr(defaultPath, '/');
    const char *name = slash ? slash + 1 : defaultPath;
    if (configured && configured[0]) {
        // A setuid restore inherits the UIKit host's environment. Do not let
        // the root host reuse a generated mobile rendezvous path: its child
        // would replace that file with a root-owned one and poison subsequent
        // VM starts. Explicit, non-generated developer paths remain valid.
        const char *configuredSlash = strrchr(configured, '/');
        const char *configuredName =
            configuredSlash ? configuredSlash + 1 : configured;
        size_t nameLength = strlen(name);
        if (strncmp(configuredName, name, nameLength) != 0 ||
            configuredName[nameLength] != '.')
            return configured;
        const char *uidStart = configuredName + nameLength + 1;
        char *uidEnd = NULL;
        unsigned long encodedUID = strtoul(uidStart, &uidEnd, 10);
        if (uidEnd == uidStart || *uidEnd != '.' ||
            encodedUID == (unsigned long)geteuid())
            return configured;
    }
    snprintf(storage, PATH_MAX, "%s%s.%u.%d", VZTemporaryPath(""), name,
             (unsigned)geteuid(), getpid());
    setenv(environmentName, storage, 1);
    return storage;
}

static const char *vmm_endpoint_file(void) {
    static char path[PATH_MAX];
    return session_file("VZ_VMM_ENDPOINT_FILE", DEFAULT_EP_FILE, path);
}

static const char *installation_endpoint_file(void) {
    static char path[PATH_MAX];
    return session_file("VZ_INSTALLATION_ENDPOINT_FILE",
                        DEFAULT_INSTALLATION_EP_FILE, path);
}

static void L(const char *fmt, ...) {
    FILE *f = fopen(VZTemporaryPath("vzxpchook.log"), "a"); if (!f) return;
    fchmod(fileno(f), VZLogMode);
    struct timespec now = {0};
    clock_gettime(CLOCK_MONOTONIC, &now);
    fprintf(f, "[%lld.%06ld] ", (long long)now.tv_sec,
            now.tv_nsec / 1000);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap); fputc('\n', f); fclose(f);
}

// Stale files are diagnostic debris, not a reason to make a VM unusable. If
// another identity owns a rendezvous file (or a PID was reused), move this
// launch to a fresh path and propagate it to the child through its environment.
static const char *prepare_endpoint_file(const char *environmentName,
                                         const char *defaultPath,
                                         const char *candidate,
                                         char replacement[PATH_MAX]) {
    if (unlink(candidate) == 0 || errno == ENOENT)
        return candidate;

    int originalError = errno;
    const char *slash = strrchr(defaultPath, '/');
    const char *name = slash ? slash + 1 : defaultPath;
    for (int attempt = 0; attempt < 8; attempt++) {
        snprintf(replacement, PATH_MAX, "%s%s.%u.%d.%08x", VZTemporaryPath(""), name,
                 (unsigned)geteuid(), getpid(), arc4random());
        if (unlink(replacement) == 0 || errno == ENOENT) {
            setenv(environmentName, replacement, 1);
            L("[vzxpchook] endpoint cleanup path=%s errno=%d; "
              "continuing with path=%s", candidate, originalError,
              replacement);
            return replacement;
        }
    }
    L("[vzxpchook] endpoint cleanup path=%s errno=%d; could not "
      "allocate a fallback path", candidate, originalError);
    return NULL;
}

static void cleanup_installation_child(void) {
    pid_t pid = __atomic_exchange_n(&gInstallationPID, 0,
                                    __ATOMIC_ACQ_REL);
    if (pid > 0) {
        int result = kill(pid, SIGKILL);
        L("[vzxpchook] installation cleanup pid=%d result=%d errno=%d",
          pid, result, result == 0 ? 0 : errno);
    }
}

__attribute__((constructor)) static void _init(void) {
    const char *debugValue = getenv("VZ_DEBUG_LOGGING");
    gDebugLogging = debugValue && debugValue[0] &&
        strcmp(debugValue, "0") != 0;
    L("[vzxpchook] loaded pid %d", getpid());
    atexit(cleanup_installation_child);
}

static void log_factory_result_register(task_t task, int stopCount) {
    if (!MACH_PORT_VALID(task))
        return;
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t threadCount = 0;
    kern_return_t kr = task_threads(task, &threads, &threadCount);
    if (kr != KERN_SUCCESS) {
        L("[vzxpchook] VMM factory stop %d task_threads kr=%d",
          stopCount, kr);
        return;
    }
    BOOL found = NO;
    for (mach_msg_type_number_t i = 0; i < threadCount; i++) {
        arm_thread_state64_t state = {0};
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        kr = thread_get_state(
            threads[i], ARM_THREAD_STATE64,
            (thread_state_t)&state, &count);
        if (kr != KERN_SUCCESS)
            continue;
        // The patched factory thread has just returned from kill(SIGSTOP).
        // x16 remains SYS_kill (the kernel clears x1); x26 still contains
        // the factory's tagged result, whose low bit is the success flag.
        if (state.__x[16] == 37) {
            found = YES;
            L("[vzxpchook] VMM factory stop %d result=0x%llx "
              "success-bit=%llu pc=0x%llx",
              stopCount, (unsigned long long)state.__x[26],
              (unsigned long long)(state.__x[26] & 1),
              (unsigned long long)arm_thread_state64_get_pc(state));
        }
    }
    if (!found)
        L("[vzxpchook] VMM factory stop %d result thread not found",
          stopCount);
    for (mach_msg_type_number_t i = 0; i < threadCount; i++)
        mach_port_deallocate(mach_task_self(), threads[i]);
    vm_deallocate(
        mach_task_self(), (vm_address_t)threads,
        (vm_size_t)(threadCount * sizeof(thread_t)));
}

// child env = our env minus DYLD_INSERT_LIBRARIES (the VMM loads vmmhook via a linked dep,
// not via DYLD_INSERT — we don't want our host hook in the child).
static char **child_env(void) {
    int n = 0; for (char **e = environ; *e; e++) n++;
    char **out = (char **)malloc(sizeof(char *) * (n + 1));
    int j = 0;
    for (char **e = environ; *e; e++)
        if (strncmp(*e, "DYLD_INSERT_LIBRARIES=", 22) != 0) out[j++] = *e;
    out[j] = NULL;
    return out;
}

static xo_t spawn_vmm_and_connect(dispatch_queue_t cq) {
    gVZConnectionQueue = cq;
    const char *endpointFile = vmm_endpoint_file();
    static char replacementEndpointFile[PATH_MAX];
    endpointFile = prepare_endpoint_file(
        "VZ_VMM_ENDPOINT_FILE", DEFAULT_EP_FILE, endpointFile,
        replacementEndpointFile);
    if (!endpointFile)
        return NULL;
    const char *vmm_bin = getenv("VZ_VMM_BIN");
    if (!vmm_bin || !vmm_bin[0]) vmm_bin = DEFAULT_VMM_BIN;
    // A restore runs through the setuid launcher while ordinary VM boots run
    // as mobile. Keep their stderr files separate: otherwise the root restore
    // recreates /tmp/vmm.stderr.log as 0644 and every later mobile
    // posix_spawn fails with EACCES before the VMM executable is reached.
    const char *stderrPath = getenv("VZ_VMM_STDERR_LOG");
    if (!stderrPath || !stderrPath[0])
        stderrPath = VZTemporaryPath("vmm.stderr.log");
    // propagate VMMHOOK_DEBUG_SLEEP to the child by NOT stripping it (child_env keeps everything
    // except DYLD_INSERT_LIBRARIES; getenv VMMHOOK_DEBUG_SLEEP set on host inherits to child)
    // A Taurine restore enters through the setuid launcher rather than the
    // app's already-jailbroken process tree. Reproduce jbexec's preflight:
    // stage2 prepares a suspended target for jailbreakd, after which we resume
    // that same child instead of killing it as the standalone preflight tool
    // does. Dopamine has no stage2 image and keeps the direct-spawn path.
    BOOL taurinePreflight = access(
        "/usr/lib/pspawn_payload-stg2.dylib", R_OK) == 0;
    const char *oldPreflight = getenv("PREFLIGHT");
    char *savedPreflight = oldPreflight ? strdup(oldPreflight) : NULL;
    if (taurinePreflight) {
        setenv("PREFLIGHT", "1", 1);
        if (!dlopen("/usr/lib/pspawn_payload-stg2.dylib",
                    RTLD_NOW | RTLD_GLOBAL)) {
            L("[vzxpchook] Taurine stage2 load failed: %s", dlerror());
            taurinePreflight = NO;
        }
    }
    char *argv[] = { (char *)vmm_bin, NULL };
    char **envp = child_env();
    // Redirect the VMM's stdout and stderr so launch failures remain visible.
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, stderrPath, O_WRONLY|O_CREAT|O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(&fa, 2, stderrPath, O_WRONLY|O_CREAT|O_APPEND, 0644);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    if (taurinePreflight)
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_START_SUSPENDED);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, vmm_bin, &fa, &attributes, argv, envp);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&fa);
    free(envp);
    if (savedPreflight) {
        setenv("PREFLIGHT", savedPreflight, 1);
        free(savedPreflight);
    } else {
        unsetenv("PREFLIGHT");
    }
    L("[vzxpchook] posix_spawn rc=%d pid=%d taurine-preflight=%d "
      "target=%s stderr=%s", rc, pid, taurinePreflight, vmm_bin,
      stderrPath);
    if (rc != 0) return NULL;
    task_t ctask = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &ctask);
    L("[vzxpchook] early task_for_pid kr=%d ctask=0x%x", kr, ctask);
    if (taurinePreflight) {
        int resumeResult = kill(pid, SIGCONT);
        L("[vzxpchook] Taurine prepared child resume result=%d errno=%d",
          resumeResult, resumeResult == 0 ? 0 : errno);
    }
    useconds_t factorySettleUsec = 2000000;
    useconds_t factoryLongSettleUsec = 0;
    int factoryLongStop = 0;
    const char *factorySettleString = getenv("VMM_FACTORY_SETTLE_USEC");
    if (factorySettleString && factorySettleString[0]) {
        unsigned long parsed = strtoul(factorySettleString, NULL, 10);
        if (parsed >= 1000 && parsed <= 30000000)
            factorySettleUsec = (useconds_t)parsed;
    }
    const char *factoryLongStopString = getenv("VMM_FACTORY_LONG_STOP");
    if (factoryLongStopString && factoryLongStopString[0])
        factoryLongStop = atoi(factoryLongStopString);
    const char *factoryLongSettleString =
        getenv("VMM_FACTORY_LONG_SETTLE_USEC");
    if (factoryLongSettleString && factoryLongSettleString[0]) {
        unsigned long parsed = strtoul(factoryLongSettleString, NULL, 10);
        if (parsed >= 1000 && parsed <= 30000000)
            factoryLongSettleUsec = (useconds_t)parsed;
    }
    // The VMM factory patch stops the whole child after each serialized
    // device factory, reproducing LLDB's successful all-thread stop. Resume it
    // periodically while start is in flight; SIGCONT is harmless when running.
    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        L("[vzxpchook] VMM factory supervisor started pid=%d", pid);
        L("[vzxpchook] VMM factory settle interval usec=%u",
          factorySettleUsec);
        L("[vzxpchook] VMM factory long stop=%d usec=%u",
          factoryLongStop, factoryLongSettleUsec);
        int stopCount = 0;
        for (int i = 0; i < 6000; i++) {
            int status = 0;
            pid_t changed = waitpid(pid, &status, WNOHANG | WUNTRACED);
            if (changed == pid && WIFSTOPPED(status)) {
                stopCount++;
                L("[vzxpchook] VMM factory stop %d signal=%d",
                  stopCount, WSTOPSIG(status));
                log_factory_result_register(ctask, stopCount);
                useconds_t delay =
                    stopCount == factoryLongStop && factoryLongSettleUsec
                    ? factoryLongSettleUsec : factorySettleUsec;
                L("[vzxpchook] VMM factory stop %d settle-usec=%u",
                  stopCount, delay);
                usleep(delay);
                kill(pid, SIGCONT);
            } else if (changed == pid &&
                       (WIFEXITED(status) || WIFSIGNALED(status))) {
                L("[vzxpchook] VMM exited status=%d signal=%d",
                  WIFEXITED(status) ? WEXITSTATUS(status) : -1,
                  WIFSIGNALED(status) ? WTERMSIG(status) : 0);
                break;
            } else {
                usleep(10000);
            }
        }
        L("[vzxpchook] VMM factory supervisor finished pid=%d stops=%d",
          pid, stopCount);
    });

    // wait for the VMM (its vmmhook listener) to publish its endpoint port name
    uint32_t myport = 0;
    // Keep the rendezvous window generous enough for a debugger attachment.
    // Normal launches publish in well under a second.
    for (int i = 0; i < 1200 && !myport; i++) {
        FILE *f = fopen(endpointFile, "r");
        if (f) { if (fscanf(f, "%x", &myport) != 1) myport = 0; fclose(f); }
        if (!myport) usleep(50000);   // 50ms; up to ~60s
    }
    if (!myport) {
        L("[vzxpchook] TIMEOUT waiting for VMM to publish port path=%s",
          endpointFile);
        return NULL;
    }
    L("[vzxpchook] VMM published listener port 0x%x", myport);

    // extract a send-right to the VMM's listener port into OUR namespace (we have task_for_pid)
    if (kr != KERN_SUCCESS) return NULL;
    mach_port_t hsend = MACH_PORT_NULL; mach_msg_type_name_t aq = 0;
    kr = mach_port_extract_right(ctask, myport, MACH_MSG_TYPE_COPY_SEND, &hsend, &aq);
    L("[vzxpchook] extract_right kr=%d hsend=0x%x", kr, hsend);
    if (kr != KERN_SUCCESS) return NULL;

    // rebuild the VMM's endpoint (port-swap) and connect in as the client
    dispatch_queue_t lq = dispatch_queue_create("vmm.shape", DISPATCH_QUEUE_SERIAL);
    xo_t dummy = xpc_connection_create(NULL, lq);
    xpc_connection_set_event_handler(dummy, ^(xo_t e) {});
    xpc_connection_resume(dummy);
    xo_t ep = xpc_endpoint_create(dummy);
    *(uint32_t *)((char *)ep + EP_PORT_OFF) = hsend;
    xo_t conn = xpc_connection_create_from_endpoint(ep);
    L("[vzxpchook] reconstructed VMM endpoint -> conn=%p (returning to VZ)", conn);
    return conn;
}

static xo_t spawn_installation_and_connect(dispatch_queue_t cq) {
    (void)cq;
    pthread_mutex_lock(&gInstallationLock);
    if (gInstallationEndpoint) {
        xo_t connection =
            xpc_connection_create_from_endpoint(gInstallationEndpoint);
        if (connection && gInstallationConnectionCount <
                              sizeof(gInstallationConnections) /
                                  sizeof(gInstallationConnections[0]))
            gInstallationConnections[gInstallationConnectionCount++] =
                connection;
        L("[vzxpchook] reused installation listener endpoint=%p "
          "connection=%p peer=%zu",
          gInstallationEndpoint, connection,
          gInstallationConnectionCount);
        pthread_mutex_unlock(&gInstallationLock);
        return connection;
    }
    const char *endpointFile = installation_endpoint_file();
    static char replacementEndpointFile[PATH_MAX];
    endpointFile = prepare_endpoint_file(
        "VZ_INSTALLATION_ENDPOINT_FILE", DEFAULT_INSTALLATION_EP_FILE,
        endpointFile, replacementEndpointFile);
    if (!endpointFile) {
        pthread_mutex_unlock(&gInstallationLock);
        return NULL;
    }
    const char *binary = getenv("VZ_INSTALLATION_BIN");
    if (!binary || !binary[0])
        binary = DEFAULT_INSTALLATION_BIN;
    char **envp = child_env();
    char *argv[] = { (char *)binary, NULL };
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(
        &actions, 1, VZTemporaryPath("installation.stderr.log"),
        O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_addopen(
        &actions, 2, VZTemporaryPath("installation.stderr.log"),
        O_WRONLY | O_CREAT | O_APPEND, 0644);
    pid_t pid = 0;
    int rc = posix_spawn(&pid, binary, &actions, NULL, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    free(envp);
    L("[vzxpchook] installation posix_spawn rc=%d pid=%d path=%s",
      rc, pid, binary);
    if (rc != 0) {
        pthread_mutex_unlock(&gInstallationLock);
        return NULL;
    }
    __atomic_store_n(&gInstallationPID, pid, __ATOMIC_RELEASE);

    task_t childTask = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &childTask);
    L("[vzxpchook] installation task_for_pid kr=%d task=0x%x",
      kr, childTask);
    if (kr != KERN_SUCCESS) {
        pthread_mutex_unlock(&gInstallationLock);
        return NULL;
    }

    uint32_t childPort = 0;
    for (int i = 0; i < 1200 && !childPort; i++) {
        FILE *file = fopen(endpointFile, "r");
        if (file) {
            if (fscanf(file, "%x", &childPort) != 1)
                childPort = 0;
            fclose(file);
        }
        if (!childPort) {
            int status = 0;
            if (waitpid(pid, &status, WNOHANG) == pid) {
                L("[vzxpchook] installation exited before endpoint "
                  "status=%d signal=%d",
                  WIFEXITED(status) ? WEXITSTATUS(status) : -1,
                  WIFSIGNALED(status) ? WTERMSIG(status) : 0);
                pthread_mutex_unlock(&gInstallationLock);
                return NULL;
            }
            usleep(50000);
        }
    }
    if (!childPort) {
        L("[vzxpchook] timeout waiting for installation endpoint");
        pthread_mutex_unlock(&gInstallationLock);
        return NULL;
    }
    L("[vzxpchook] installation published port 0x%x", childPort);

    mach_port_t sendRight = MACH_PORT_NULL;
    mach_msg_type_name_t acquiredType = 0;
    kr = mach_port_extract_right(
        childTask, childPort, MACH_MSG_TYPE_COPY_SEND,
        &sendRight, &acquiredType);
    L("[vzxpchook] installation extract_right kr=%d send=0x%x",
      kr, sendRight);
    if (kr != KERN_SUCCESS) {
        pthread_mutex_unlock(&gInstallationLock);
        return NULL;
    }

    dispatch_queue_t shapeQueue =
        dispatch_queue_create("installation.shape", DISPATCH_QUEUE_SERIAL);
    xo_t dummy = xpc_connection_create(NULL, shapeQueue);
    xpc_connection_set_event_handler(dummy, ^(xo_t event) { (void)event; });
    xpc_connection_resume(dummy);
    xo_t endpoint = xpc_endpoint_create(dummy);
    *(uint32_t *)((char *)endpoint + EP_PORT_OFF) = sendRight;
    gInstallationEndpoint = xpc_retain(endpoint);
    xo_t connection = xpc_connection_create_from_endpoint(endpoint);
    if (connection)
        gInstallationConnections[gInstallationConnectionCount++] = connection;
    L("[vzxpchook] reconstructed installation listener endpoint=%p "
      "connection=%p peer=%zu",
      gInstallationEndpoint, connection, gInstallationConnectionCount);
    dispatch_async(
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        pid_t changed;
        do {
            changed = waitpid(pid, &status, 0);
        } while (changed < 0 && errno == EINTR);
        if (changed == pid) {
            pid_t expected = pid;
            __atomic_compare_exchange_n(
                &gInstallationPID, &expected, 0, false,
                __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
            L("[vzxpchook] installation child exited status=%d signal=%d",
              WIFEXITED(status) ? WEXITSTATUS(status) : -1,
              WIFSIGNALED(status) ? WTERMSIG(status) : 0);
        } else {
            L("[vzxpchook] installation waitpid failed pid=%d errno=%d",
              pid, errno);
        }
    });
    pthread_mutex_unlock(&gInstallationLock);
    return connection;
}

static BOOL is_installation_connection(xo_t connection) {
    BOOL found = NO;
    pthread_mutex_lock(&gInstallationLock);
    for (size_t i = 0; i < gInstallationConnectionCount; i++) {
        if (gInstallationConnections[i] == connection) {
            found = YES;
            break;
        }
    }
    pthread_mutex_unlock(&gInstallationLock);
    return found;
}

// Export the exact weak flat-namespace name used by the extracted
// Virtualization framework. This works both when the hook is injected at
// process launch and when a UIKit host dlopens it before Virtualization.
xo_t xpc_connection_create(const char *name, dispatch_queue_t q) {
    L("[vzxpchook] xpc_connection_create(%s)", name ? name : "(null)");
    static xo_t (*real)(const char *, dispatch_queue_t) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "xpc_connection_create");
    if (name && strcmp(name, VMM_NAME) == 0) {
        xo_t connection = spawn_vmm_and_connect(q);
        if (connection)
            return connection;
        L("[vzxpchook] VMM rendezvous failed; returning a real XPC "
          "connection so Virtualization reports an error instead of "
          "dereferencing NULL");
    }
    if (name && strcmp(name, INSTALLATION_NAME) == 0) {
        xo_t connection = spawn_installation_and_connect(q);
        if (connection)
            return connection;
        L("[vzxpchook] Installation rendezvous failed; returning a real XPC "
          "connection so Virtualization reports an error instead of "
          "dereferencing NULL");
    }
    return real ? real(name, q) : NULL;
}

static void vz_xpc_connection_send_message_with_reply(
    xo_t connection, xo_t message, dispatch_queue_t queue,
    void (^handler)(xo_t)) {
    const char *name = xpc_dictionary_get_string(message, "name");
    if (is_installation_connection(connection)) {
        char *requestDescription = xpc_copy_description(message);
        L("[vzxpchook] installation request %s",
          requestDescription ?: "(no description)");
        free(requestDescription);
        xpc_connection_send_message_with_reply(
            connection, message, queue, ^(xo_t reply) {
            char *replyDescription = xpc_copy_description(reply);
            L("[vzxpchook] installation reply %s",
              replyDescription ?: "(no description)");
            free(replyDescription);
            xo_t result = xpc_dictionary_get_value(reply, "result");
            xo_t value = result
                ? xpc_dictionary_get_value(result, "value") : NULL;
            const void *bytes = value ? xpc_data_get_bytes_ptr(value) : NULL;
            size_t byteCount = value ? xpc_data_get_length(value) : 0;
            if (bytes && byteCount) {
                FILE *dump = fopen(VZTemporaryPath("installation-reply.bin"), "wb");
                if (dump) {
                    fwrite(bytes, 1, byteCount, dump);
                    fclose(dump);
                    L("[vzxpchook] dumped installation reply bytes=%zu",
                      byteCount);
                }
            }
            handler(reply);
        });
        return;
    }
    if (name && (strstr(name, "keyboard") || strstr(name, "digitizer") ||
                 strstr(name, "pointing") || strstr(name, "trackpad"))) {
        uint64_t count = diagnostic_sequence(&gInputSendCount, 12);
        if (count && count <= 12) {
            char *description = xpc_copy_description(message);
            L("[vzxpchook] input %llu send-with-reply %s %s",
              (unsigned long long)count, name,
              description ?: "(no description)");
            free(description);
        }
    }
    if (name && strcmp(name, "start_virtual_machine") == 0) {
        char *description = xpc_copy_description(message);
        L("[vzxpchook] VMM start request %s",
          description ?: "(no description)");
        free(description);
        xo_t arguments = xpc_dictionary_get_value(message, "arguments");
        xo_t options = arguments ? xpc_array_get_value(arguments, 0) : NULL;
        xo_t rates = options
            ? xpc_dictionary_get_value(options, "framebuffer_frame_rates")
            : NULL;
        xo_t rate = rates && xpc_array_get_count(rates) > 0
            ? xpc_array_get_value(rates, 0) : NULL;
        if (rate) {
            uint64_t original =
                xpc_dictionary_get_uint64(rate, "frame_rate");
            L("[vzxpchook] preserving initial framebuffer rate %llu",
              (unsigned long long)original);
        }
    }
    xpc_connection_send_message_with_reply(
        connection, message, queue, handler);
}

static void send_retained_framebuffer_message_after_start(
    xo_t connection, xo_t message) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        xpc_connection_send_message(connection, message);
        xpc_release(message);
        xpc_release(connection);
    });
}

void vz_host_vm_started(void) {
    __atomic_store_n(&gVMMStarted, 1, __ATOMIC_RELEASE);
    xo_t connection = gPendingFramebufferConnection;
    xo_t message = gPendingFramebufferMessage;
    gPendingFramebufferConnection = NULL;
    gPendingFramebufferMessage = NULL;
    L("[vzxpchook] host marked VM started pending-frame=%p", message);
    if (connection && message)
        send_retained_framebuffer_message_after_start(connection, message);
    xo_t update = gPendingFrameUpdate;
    void (^handler)(xo_t) = gPendingFrameHandler;
    gPendingFrameUpdate = NULL;
    gPendingFrameHandler = NULL;
    if (update && handler) {
        dispatch_queue_t queue = gVZConnectionQueue
            ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        dispatch_async(queue, ^{
            handler(update);
            xpc_release(update);
            Block_release(handler);
        });
    }
}

static void vz_xpc_connection_send_message(xo_t connection, xo_t message) {
    const char *name = xpc_dictionary_get_string(message, "name");
    if (name && (strstr(name, "keyboard") || strstr(name, "digitizer") ||
                 strstr(name, "pointing") || strstr(name, "trackpad"))) {
        uint64_t count = diagnostic_sequence(&gInputSendCount, 12);
        if (count && count <= 12) {
            char *description = xpc_copy_description(message);
            L("[vzxpchook] input %llu send %s %s",
              (unsigned long long)count, name,
              description ?: "(no description)");
            free(description);
        }
    }
    if (name && strstr(name, "frame") != NULL) {
        xo_t retainedConnection = xpc_retain(connection);
        xo_t retainedMessage = xpc_retain(message);
        if (!__atomic_load_n(&gVMMStarted, __ATOMIC_ACQUIRE)) {
            if (gPendingFramebufferMessage) {
                xpc_release(gPendingFramebufferMessage);
                xpc_release(gPendingFramebufferConnection);
            }
            gPendingFramebufferConnection = retainedConnection;
            gPendingFramebufferMessage = retainedMessage;
            L("[vzxpchook] holding pre-start framebuffer control message %s",
              name);
        } else {
            // did_process_frame_update is the VMM's buffer-credit ACK. Delaying
            // every ACK exhausts its finite in-flight surface pool after the
            // first few frames, leaving a perfectly live guest behind a stale
            // desktop. Startup may still need the one pre-start message held,
            // but steady-state acknowledgements must retain their ordering and
            // return synchronously to XPC.
            xpc_release(retainedMessage);
            xpc_release(retainedConnection);
            uint64_t count = diagnostic_sequence(&gFrameAckCount, 8);
            if (count && (count <= 8 ||
                          (gDebugLogging && count % 300 == 0)))
                L("[vzxpchook] framebuffer ACK %llu %s immediate",
                  (unsigned long long)count, name);
            xpc_connection_send_message(connection, message);
        }
        return;
    }
    xpc_connection_send_message(connection, message);
}

static void vz_xpc_connection_set_event_handler(
    xo_t connection, void (^handler)(xo_t)) {
    xpc_connection_set_event_handler(connection, ^(xo_t event) {
        const char *name = xpc_dictionary_get_string(event, "name");
        uint64_t count = diagnostic_sequence(&gHostEventCount, 12);
        BOOL important = name &&
            (strcmp(name, "guest_did_panic") == 0 ||
             strcmp(name, "guest_did_stop_virtual_machine") == 0 ||
             strcmp(name, "guest_did_reset_virtual_machine") == 0);
        if (important || (count && (count <= 12 ||
            (gDebugLogging && count % 300 == 0)))) {
            char *description = xpc_copy_description(event);
            L("[vzxpchook] host event %llu name=%s %s",
              (unsigned long long)count, name ?: "(null)",
              description ?: "(no description)");
            free(description);
        }
        if (name && strcmp(name, "process_frame_update") == 0 &&
            !__atomic_load_n(&gVMMStarted, __ATOMIC_ACQUIRE)) {
            if (gPendingFrameUpdate)
                xpc_release(gPendingFrameUpdate);
            if (gPendingFrameHandler)
                Block_release(gPendingFrameHandler);
            gPendingFrameUpdate = xpc_retain(event);
            gPendingFrameHandler = Block_copy(handler);
            L("[vzxpchook] holding pre-start process_frame_update");
            return;
        }
        handler(event);
    });
}

// The frame RPC decoder returns false when IOSurfaceLookupFromXPCObject
// rejects the cross-process object. Rebind this one import while porting so
// the first few lookups record the exact object and whether the native iOS
// IOSurface implementation accepted it. This is a framebuffer hot path: a
// file open, XPC description allocation, and write for every frame can build
// an old-frame backlog under memory and storage pressure.
static void *vz_IOSurfaceLookupFromXPCObject(xo_t object) {
    static void *(*realLookup)(xo_t);
    static void *(*lookupFromMachPort)(mach_port_t);
    static void *(*lookupFromID)(uint32_t);
    if (!realLookup) {
        void *image = dlopen(
            "/System/Library/Frameworks/IOSurface.framework/IOSurface",
            RTLD_NOW | RTLD_LOCAL);
        realLookup = image
            ? (void *(*)(xo_t))dlsym(image, "IOSurfaceLookupFromXPCObject")
            : NULL;
        lookupFromMachPort = image
            ? (void *(*)(mach_port_t))dlsym(
                  image, "IOSurfaceLookupFromMachPort")
            : NULL;
        lookupFromID = image
            ? (void *(*)(uint32_t))dlsym(image, "IOSurfaceLookup")
            : NULL;
    }
    void *type = xpc_get_type(object);
    void *surface = realLookup ? realLookup(object) : NULL;
    mach_port_t port = MACH_PORT_NULL;
    if (!surface && type == (void *)_xpc_type_mach_send &&
        lookupFromMachPort) {
        port = xpc_mach_send_get_right(object);
        if (MACH_PORT_VALID(port))
            surface = lookupFromMachPort(port);
    }
    uint64_t identifier = type == (void *)_xpc_type_dictionary
        ? xpc_dictionary_get_uint64(
              object, "virtual_mac_surface_id")
        : 0;
    if (!surface && identifier && identifier <= UINT32_MAX && lookupFromID)
        surface = lookupFromID((uint32_t)identifier);
    uint64_t count = diagnostic_sequence(&gSurfaceLookupCount, 8);
    if (count && (count <= 8 || (gDebugLogging && count % 300 == 0))) {
        char *description = xpc_copy_description(object);
        L("[vzxpchook] IOSurfaceLookupFromXPCObject #%llu (%s) -> %p "
          "real=%p port=0x%x fallback=%p global-id=%llu lookup-id=%p",
          (unsigned long long)count,
          description ?: "(no description)", surface, realLookup,
          port, lookupFromMachPort, (unsigned long long)identifier,
          lookupFromID);
        free(description);
    }
    return surface;
}

// VZ's start path calls sandbox_extension_issue_generic_to_process to issue per-device
// sandbox extensions (e.g. "com.apple.virtualization.extension.audio-output") that the VMM
// child would consume. On iOS the symbol is weak-import and returns 0 -> VZ throws
// VZErrorInternal ("Failed to retrieve cache directory.", a misleading generic message; the
// real cause is the failed extension issue at Virtualization.ios+0x37dc8). Our spawned VMM
// runs with the no-sandbox entitlement, so the extension is moot. Return a
// dummy token string so VZ proceeds; pair with a no-op release. NB: if the VMM later
// validates the token via sandbox_extension_consume, the same interpose pair must also live
// in the VMM (vmnetstub.ios) — added there if/when that next layer surfaces.
// EXPORT the symbols (not __interpose) — the framework's auth-bind is FLAT-NAMESPACE
// weak-import (per dyld_info), unresolved on iOS, so __interpose can't redirect a NULL GOT.
// dyld's flat lookup over all loaded images WILL find our export and bind the framework's
// auth-GOT slot to it. Same trick covers any future flat weak-imports.
typedef long sxh_t;
char *sandbox_extension_issue_generic_to_process(const char *name, unsigned int flags, void *audit_token) {
    // The private API returns a malloc-owned C string, not an integer handle.
    // Virtualization stores this pointer and later serializes it with strlen(),
    // then frees it. Returning integer 1 happened to pass its NULL check but
    // crashed at _platform_strlen when the extension list was encoded.
    static const char dummy[] = "VirtualMac-no-sandbox";
    char *token = strdup(dummy);
    L("[vzxpchook] sandbox_extension_issue_generic_to_process(%s, flags=%u, audit=%p) -> %p '%s'",
      name ? name : "(null)", flags, audit_token, token, dummy);
    return token;
}
int sandbox_extension_release(sxh_t h) {
    L("[vzxpchook] sandbox_extension_release(%ld) -> 0", (long)h);
    return 0;
}

// The extracted framework is the macOS 13.2.1 22D68 image, but an unmodified
// sysctl on the iPad reports the iPadOS 16.3.1 build (20D67). Virtualization
// serializes that value as host_build in the VMM configuration. Keep the
// framework and VMM on their own compatibility path by overriding only this
// one read-only sysctl; all other names retain native iPadOS behavior.
static int vz_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                           void *newp, size_t newlen) {
    if (name && strcmp(name, "kern.osversion") == 0 && newp == NULL) {
        static const char build[] = "22D68";
        if (!oldlenp) {
            errno = EFAULT;
            return -1;
        }
        size_t available = *oldlenp;
        *oldlenp = sizeof(build);
        if (!oldp) {
            L("[vzxpchook] sysctlbyname(kern.osversion) size -> %zu",
              sizeof(build));
            return 0;
        }
        if (available < sizeof(build)) {
            if (available)
                memcpy(oldp, build, available);
            errno = ENOMEM;
            return -1;
        }
        memcpy(oldp, build, sizeof(build));
        L("[vzxpchook] sysctlbyname(kern.osversion) -> %s", build);
        return 0;
    }
    static int (*real_sysctlbyname)(const char *, void *, size_t *,
                                    void *, size_t);
    if (!real_sysctlbyname)
        real_sysctlbyname = dlsym(RTLD_NEXT, "sysctlbyname");
    return real_sysctlbyname
        ? real_sysctlbyname(name, oldp, oldlenp, newp, newlen)
        : -1;
}

// The extracted 22D68 Virtualization image retains authenticated GOT slots
// from its dyld-shared-cache layout. dyld_dynamic_interpose cannot enumerate
// those cache-origin entries after extraction, so a UIKit host that dlopens
// this hook must explicitly rebind the small host-compatibility surface.
// Each stub uses BRAA x16,x17; sign the replacement with IA and the slot
// address as its discriminator.
int vz_rebind_virtualization(void *imageBase) {
#if __has_feature(ptrauth_calls)
    char productVersion[32] = {0};
    size_t productVersionSize = sizeof(productVersion);
    bool isPreIOS16 = vz_sysctlbyname(
        "kern.osproductversion", productVersion, &productVersionSize,
        NULL, 0) == 0 && strtol(productVersion, NULL, 10) < 16;
    void *objcRelease = isPreIOS16
        ? dlsym(RTLD_DEFAULT, "objc_release") : NULL;
    void *objcRetain = isPreIOS16
        ? dlsym(RTLD_DEFAULT, "objc_retain") : NULL;
    struct Rebind {
        uintptr_t offset;
        void *replacement;
        const char *name;
        bool preIOS16Only;
    } rebinds[] = {
        {0x147288, (void *)&vz_IOSurfaceLookupFromXPCObject,
                   "IOSurfaceLookupFromXPCObject", false},
        {0x147648, (void *)&confstr, "confstr", false},
        // Ventura's compiler emits the register-specialized retain/release
        // entry points added after iPadOS 15. Their ordinary libobjc forms
        // have the same x0 argument/return contract needed at these call
        // sites. Repair only the absent iPadOS 15 slots; iPadOS 16's native
        // optimized bindings are never read or overwritten here.
        {0x147970, objcRelease, "objc_release_x0 -> objc_release", true},
        {0x147978, objcRetain, "objc_retain_x0 -> objc_retain", true},
        {0x147ae0, (void *)&vz_sysctlbyname, "sysctlbyname", false},
        {0x147a80, (void *)&sandbox_extension_issue_generic_to_process,
                   "sandbox_extension_issue_generic_to_process", false},
        {0x147a88, (void *)&sandbox_extension_release,
                   "sandbox_extension_release", false},
        {0x147b98, (void *)&xpc_connection_create,
                   "xpc_connection_create", false},
        {0x147bb8, (void *)&vz_xpc_connection_send_message,
                   "xpc_connection_send_message", false},
        {0x147bc0, (void *)&vz_xpc_connection_send_message_with_reply,
                   "xpc_connection_send_message_with_reply", false},
        {0x147bc8, (void *)&vz_xpc_connection_set_event_handler,
                   "xpc_connection_set_event_handler", false},
    };
    uintptr_t base = (uintptr_t)imageBase;
    uintptr_t page = (base + rebinds[0].offset) & ~(uintptr_t)0x3fff;
    uintptr_t end =
        (base + rebinds[sizeof(rebinds) / sizeof(rebinds[0]) - 1].offset +
         sizeof(void *) + 0x3fff) &
        ~(uintptr_t)0x3fff;
    kern_return_t kr = vm_protect(
        mach_task_self(), (vm_address_t)page, (vm_size_t)(end - page),
        false, VM_PROT_READ | VM_PROT_WRITE);
    L("[vzxpchook] rebind VZ base=%p protect [%p,%p) kr=%d",
      imageBase, (void *)page, (void *)end, kr);
    if (kr != KERN_SUCCESS)
        return (int)kr;

    for (size_t i = 0; i < sizeof(rebinds) / sizeof(rebinds[0]); i++) {
        if (rebinds[i].preIOS16Only && !isPreIOS16)
            continue;
        if (!rebinds[i].replacement) {
            L("[vzxpchook] missing iPadOS 15 replacement for %s",
              rebinds[i].name);
            return -1;
        }
        void **slot = (void **)(base + rebinds[i].offset);
        void *old = *slot;
        void *raw = ptrauth_strip(
            rebinds[i].replacement, ptrauth_key_function_pointer);
        void *signedReplacement = ptrauth_sign_unauthenticated(
            raw, ptrauth_key_asia, (uintptr_t)slot);
        *slot = signedReplacement;
        L("[vzxpchook] rebound %s slot=%p old=%p new=%p",
          rebinds[i].name, slot, old, signedReplacement);
    }
    return 0;
#else
    L("[vzxpchook] rebind unavailable: hook was not built arm64e");
    return -1;
#endif
}

// Virtualization asks confstr for Darwin's per-user temp/cache roots before
// starting the VMM. iPadOS exposes the selectors but returns 0 for them to
// this non-containerized root process. Supply a real writable root for only
// those selectors and preserve libc behavior for every other name.
size_t confstr(int name, char *buffer, size_t length) {
    if (name == 65537 || name == 65538) {
        const char *path = VZTemporaryPath("");
        size_t required = strlen(path) + 1;
        if (buffer && length) {
            size_t copied = required < length ? required : length;
            memcpy(buffer, path, copied);
            buffer[length - 1] = '\0';
        }
        L("[vzxpchook] confstr(%d) -> %s", name, path);
        return required;
    }
    static size_t (*real_confstr)(int, char *, size_t);
    if (!real_confstr)
        real_confstr = dlsym(RTLD_NEXT, "confstr");
    return real_confstr ? real_confstr(name, buffer, length) : 0;
}
