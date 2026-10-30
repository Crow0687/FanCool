#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <libproc.h>

// AppleSMC's user-client ABI. C fixes padding independently of Swift layout.
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } version;
    struct { uint16_t version, length; uint32_t cpu, gpu, memory; } limit;
    struct { uint32_t size, type; uint8_t attributes; } info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} MFSMCRequest;
_Static_assert(sizeof(MFSMCRequest) == 80, "SMC packet must be 80 bytes");
_Static_assert(offsetof(MFSMCRequest, bytes) == 48, "SMC payload offset");

static uint32_t call(uint32_t connection, MFSMCRequest *request, MFSMCRequest *reply) {
    size_t length = sizeof(*reply);
    kern_return_t status = IOConnectCallStructMethod(connection, 2, request, sizeof(*request), reply, &length);
    if (status != KERN_SUCCESS) return status;
    if (length != sizeof(*reply)) return kIOReturnUnderrun;
    return reply->result == 0 ? 0 : (0x10000000u | reply->result);
}

uint32_t mf_smc_open(uint32_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMCKeysEndpoint"));
    if (!service) return kIOReturnNotFound;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return status;
}
void mf_smc_close(uint32_t connection) { if (connection) IOServiceClose(connection); }

uint32_t mf_smc_read(uint32_t connection, uint32_t key, MFSMCValue *value) {
    MFSMCRequest request = {0}, reply = {0};
    request.key = key; request.command = 9;
    uint32_t status = call(connection, &request, &reply);
    if (status) return status;
    if (reply.info.size == 0 || reply.info.size > 32) return kIOReturnBadArgument;
    value->size = reply.info.size; value->type = reply.info.type;
    request.info.size = value->size; request.command = 5;
    memset(&reply, 0, sizeof(reply));
    status = call(connection, &request, &reply);
    if (!status) memcpy(value->bytes, reply.bytes, value->size);
    return status;
}

uint32_t mf_smc_write(uint32_t connection, uint32_t key, const MFSMCValue *value) {
    if (geteuid() != 0) return kIOReturnNotPrivileged;
    if (!value->size || value->size > 32) return kIOReturnBadArgument;
    MFSMCRequest request = {0}, reply = {0};
    request.key = key; request.command = 6; request.info.size = value->size;
    memcpy(request.bytes, value->bytes, value->size);
    return call(connection, &request, &reply);
}

uint32_t mf_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t *key) {
    MFSMCRequest request = {0}, reply = {0};
    request.command = 8; request.index = index;
    uint32_t status = call(connection, &request, &reply);
    if (!status) *key = reply.key;
    return status;
}

// One monitor calls this on its serial actor; first sample has no interval.
double mf_cpu_usage(void) {
    static uint64_t previous_total = 0, previous_idle = 0;
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    mach_port_t host = mach_host_self();
    kern_return_t status = host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&info, &count);
    mach_port_deallocate(mach_task_self(), host);
    if (status != KERN_SUCCESS) return -1;
    uint64_t total = 0;
    for (unsigned i = 0; i < CPU_STATE_MAX; i++) total += info.cpu_ticks[i];
    uint64_t idle = info.cpu_ticks[CPU_STATE_IDLE];
    double result = -1;
    if (previous_total && total > previous_total && idle >= previous_idle)
        result = 100.0 * (1.0 - (double)(idle - previous_idle) / (double)(total - previous_total));
    previous_total = total; previous_idle = idle;
    return result;
}

int mf_conflicting_controller(char *name, size_t capacity) {
    int length = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (length <= 0 || capacity == 0) return 0;
    pid_t *pids = calloc(1, (size_t)length + 4096);
    if (!pids) return 0;
    int count = proc_listpids(PROC_ALL_PIDS, 0, pids, length + 4096) / (int)sizeof(pid_t);
    const char *match = NULL;
    for (int i = 0; i < count; i++) {
        char process[128] = {0};
        if (proc_name(pids[i], process, sizeof(process)) <= 0) continue;
        if (strncmp(process, "Macs Fan Control", 15) == 0) { match = "Macs Fan Control"; break; }
        if (strcmp(process, "TG Pro") == 0) { match = "TG Pro"; break; }
    }
    if (match) snprintf(name, capacity, "%s", match);
    free(pids);
    return match != NULL;
}
