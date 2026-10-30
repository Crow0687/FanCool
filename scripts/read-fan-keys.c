#include "SMCBridge.h"
#include <stdio.h>
#include <string.h>

static uint32_t keycode(const char *s) {
    return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3];
}
int main(void) {
    uint32_t connection = 0;
    uint32_t status = mf_smc_open(&connection);
    if (status) { printf("SMC open: %08x\n", status); return 1; }
    const char *keys[] = {"FNum", "F0Ac", "F1Ac", "F0Tg", "F1Tg", "F0Mn", "F1Mn", "F0Mx", "F1Mx", "F0md", "F1md", "F0Md", "F1Md", "FS! ", "Ftst", "F0ID", "F1ID"};
    for (unsigned k = 0; k < sizeof(keys) / sizeof(keys[0]); k++) {
        MFSMCValue value = {0};
        status = mf_smc_read(connection, keycode(keys[k]), &value);
        if (status) { printf("%s: unavailable %08x\n", keys[k], status); continue; }
        char type[5] = {(char)(value.type >> 24), (char)(value.type >> 16), (char)(value.type >> 8), (char)value.type, 0};
        printf("%s type=%s size=%u bytes=", keys[k], type, value.size);
        for (unsigned i = 0; i < value.size; i++) printf("%02x", value.bytes[i]);
        if (!memcmp(type, "flt ", 4)) { float number = 0; memcpy(&number, value.bytes, 4); printf(" value=%.3f", number); }
        else if (!memcmp(type, "ui8 ", 4)) printf(" value=%u", value.bytes[0]);
        else if (!memcmp(type, "ui16", 4)) printf(" value=%u", value.bytes[0] * 256 + value.bytes[1]);
        printf("\n");
    }
    mf_smc_close(connection);
}
