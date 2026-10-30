#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint32_t type;
    uint32_t size;
    uint8_t bytes[32];
} MFSMCValue;

uint32_t mf_smc_open(uint32_t *connection);
void mf_smc_close(uint32_t connection);
uint32_t mf_smc_read(uint32_t connection, uint32_t key, MFSMCValue *value);
uint32_t mf_smc_write(uint32_t connection, uint32_t key, const MFSMCValue *value);
uint32_t mf_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t *key);
double mf_cpu_usage(void);
int mf_conflicting_controller(char *name, size_t capacity);
