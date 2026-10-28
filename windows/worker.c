/*
 * Experimental native Windows ADI worker, intended to run under Wine.
 * This file is NOT a replacement for Apple's CoreADI64.dll.
 * It only dispatches documented ADI requests to an operator-supplied DLL.
 *
 * Line protocol (stdin/stdout): PING, BEGIN<TAB>spim,
 * FINISH<TAB>ptm<TAB>tk, HEADERS, CANCEL, QUIT.
 * Binary fields use Base64. Only OK/ERR responses are written to stdout.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincrypt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_LINE (2 * 1024 * 1024)
#define MAX_RESULT (1024 * 1024)
#define ADI_DSID ((int64_t)-2)

typedef struct {
    unsigned char *payload;
    uint32_t input_size;
    uint32_t output_size;
    uint32_t flags;
} ADIParams;

typedef int32_t (*Dispatch)(uint32_t, const ADIParams *);
static Dispatch dispatch_fn = NULL;

static void be32(unsigned char **cursor, uint32_t n) {
    unsigned char *p = *cursor;
    p[0] = (unsigned char)(n >> 24);
    p[1] = (unsigned char)(n >> 16);
    p[2] = (unsigned char)(n >> 8);
    p[3] = (unsigned char)n;
    *cursor += 4;
}
static void be64(unsigned char **cursor, uint64_t n) {
    be32(cursor, (uint32_t)(n >> 32));
    be32(cursor, (uint32_t)n);
}
static void ptr64(unsigned char **cursor, const void *ptr) {
    be64(cursor, (uint64_t)(uintptr_t)ptr);
}
static void request_header(unsigned char **cursor) {
    be32(cursor, 1); /* unencrypted */
    be32(cursor, 1); /* marker */
}
static int32_t invoke(uint32_t function, unsigned char *message, size_t size) {
    ADIParams params = { message, (uint32_t)size, 4, 0 };
    int32_t result = dispatch_fn(function, &params);
    if (result < 0) return result;
    /* The called ADI function returns another status in the output slot. */
    return (int32_t)(((uint32_t)message[0] << 24)
        | ((uint32_t)message[1] << 16)
        | ((uint32_t)message[2] << 8) | message[3]);
}
static int32_t no_args(uint32_t function) {
    unsigned char message[64] = {0}, *p = message;
    request_header(&p);
    return invoke(function, message, (size_t)(p - message));
}
static int32_t dispose(const void *buffer) {
    if (!buffer) return 0;
    unsigned char message[64] = {0}, *p = message;
    request_header(&p);
    ptr64(&p, buffer);
    return invoke(0x3e58e7f9, message, (size_t)(p - message));
}
static int32_t destroy_session(uint32_t session) {
    unsigned char message[64] = {0}, *p = message;
    request_header(&p);
    be32(&p, session);
    return invoke(0x55a637c0, message, (size_t)(p - message));
}
static int32_t set_routing(uint64_t routing) {
    unsigned char message[64] = {0}, *p = message;
    request_header(&p);
    be64(&p, (uint64_t)ADI_DSID);
    be64(&p, routing);
    return invoke(0x632b8d6e, message, (size_t)(p - message));
}
static int32_t get_routing(uint64_t *routing) {
    unsigned char message[64] = {0}, *p = message;
    request_header(&p);
    be64(&p, (uint64_t)ADI_DSID);
    ptr64(&p, routing);
    return invoke(0x85fe63b0, message, (size_t)(p - message));
}
static char *base64_encode(const unsigned char *src, DWORD size) {
    DWORD cap = 0;
    const DWORD flags = CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF;
    if (!CryptBinaryToStringA(src, size, flags, NULL, &cap)) return NULL;
    char *out = (char *)malloc((size_t)cap + 1);
    if (!out) return NULL;
    if (!CryptBinaryToStringA(src, size, flags, out, &cap)) {
        free(out);
        return NULL;
    }
    out[cap] = '\0';
    return out;
}
static unsigned char *base64_decode(const char *s, DWORD *size) {
    if (!s || strlen(s) > MAX_LINE - 64) return NULL;
    DWORD cap = 0;
    if (!CryptStringToBinaryA(s, 0, CRYPT_STRING_BASE64, NULL, &cap, NULL, NULL)
        || cap > MAX_RESULT) return NULL;
    unsigned char *out = (unsigned char *)malloc((size_t)cap + 1);
    if (!out) return NULL;
    if (!CryptStringToBinaryA(s, 0, CRYPT_STRING_BASE64, out, &cap, NULL, NULL)) {
        free(out);
        return NULL;
    }
    *size = cap;
    return out;
}
static void error_reply(int32_t status) {
    printf("ERR\t%d\n", (int)status);
    fflush(stdout);
}
static void error_text(const char *message) {
    printf("ERR\t%s\n", message);
    fflush(stdout);
}
static void ok_reply(void) {
    puts("OK");
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        error_text("CoreADI64.dll path required");
        return 2;
    }
    HMODULE module = LoadLibraryExA(argv[1], NULL,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!module) {
        error_reply(-(int32_t)GetLastError());
        return 2;
    }
    dispatch_fn = (Dispatch)GetProcAddress(module, "vdfut768ig");
    if (!dispatch_fn) {
        error_text("Missing ADI dispatcher");
        FreeLibrary(module);
        return 2;
    }
    int32_t initialized = no_args(0x12db31c5);
    if (initialized < 0) {
        error_reply(initialized);
        FreeLibrary(module);
        return 2;
    }
    char *line = (char *)malloc(MAX_LINE);
    if (!line) return 2;
    uint32_t active_session = 0;
    while (fgets(line, MAX_LINE, stdin)) {
        size_t n = strlen(line);
        if (!n || line[n - 1] != '\n') {
            error_text("Oversized command");
            break;
        }
        char *command = strtok(line, "\t\r\n");
        if (!command) continue;
        if (!strcmp(command, "PING")) {
            ok_reply();
        } else if (!strcmp(command, "BEGIN")) {
            char *arg = strtok(NULL, "\t\r\n");
            DWORD spim_len = 0;
            unsigned char *spim = base64_decode(arg, &spim_len);
            if (!spim || active_session) {
                error_text("Invalid SPIM or busy session");
                free(spim);
                continue;
            }
            const unsigned char *cpim = NULL;
            uint32_t cpim_len = 0;
            uint32_t session = 0;
            unsigned char message[96] = {0}, *p = message;
            request_header(&p);
            be64(&p, (uint64_t)ADI_DSID);
            ptr64(&p, spim);
            be32(&p, spim_len);
            ptr64(&p, &cpim);
            ptr64(&p, &cpim_len);
            ptr64(&p, &session);
            int32_t code = invoke(0x716bd86c, message, (size_t)(p - message));
            if (code < 0 || !cpim || !cpim_len || cpim_len > MAX_RESULT || !session) {
                error_reply(code < 0 ? code : -45001);
            } else {
                active_session = session;
                char *encoded = base64_encode(cpim, cpim_len);
                if (encoded) {
                    printf("OK\t%s\n", encoded);
                    fflush(stdout);
                    free(encoded);
                } else error_text("Encoding CPIM failed");
            }
            if (cpim) (void)dispose(cpim);
            free(spim);
        } else if (!strcmp(command, "FINISH")) {
            char *ptm_arg = strtok(NULL, "\t\r\n");
            char *tk_arg = strtok(NULL, "\t\r\n");
            DWORD ptm_len = 0, tk_len = 0;
            unsigned char *ptm = base64_decode(ptm_arg, &ptm_len);
            unsigned char *tk = base64_decode(tk_arg, &tk_len);
            if (!active_session || !ptm || !tk) {
                error_text("No provisioning session or invalid PTM/TK");
            } else {
                unsigned char message[96] = {0}, *p = message;
                request_header(&p);
                be32(&p, active_session);
                ptr64(&p, ptm);
                be32(&p, ptm_len);
                ptr64(&p, tk);
                be32(&p, tk_len);
                int32_t code = invoke(0x0b2b3196, message, (size_t)(p - message));
                active_session = 0;
                if (code < 0) error_reply(code);
                else {
                    /* Legacy V3 clients do not pass X-Apple-I-MD-RINFO. */
                    code = set_routing(17106176);
                    if (code < 0) error_reply(code);
                    else ok_reply();
                }
            }
            free(ptm);
            free(tk);
        } else if (!strcmp(command, "HEADERS")) {
            const unsigned char *mid = NULL, *otp = NULL;
            uint32_t mid_len = 0, otp_len = 0;
            unsigned char message[96] = {0}, *p = message;
            request_header(&p);
            be64(&p, (uint64_t)ADI_DSID);
            ptr64(&p, &mid);
            ptr64(&p, &mid_len);
            ptr64(&p, &otp);
            ptr64(&p, &otp_len);
            int32_t code = invoke(0xcfe0b46a, message, (size_t)(p - message));
            if (code < 0 || !mid || !otp || mid_len > MAX_RESULT || otp_len > MAX_RESULT) {
                error_reply(code < 0 ? code : -45001);
            } else {
                uint64_t routing = 0;
                code = get_routing(&routing);
                char *md_b64 = base64_encode(otp, otp_len);
                char *mid_b64 = base64_encode(mid, mid_len);
                if (code < 0 || !md_b64 || !mid_b64) {
                    error_reply(code < 0 ? code : -45001);
                } else {
                    printf("OK\t%s\t%s\t%llu\n", mid_b64, md_b64,
                        (unsigned long long)routing);
                    fflush(stdout);
                }
                free(md_b64);
                free(mid_b64);
            }
            if (mid) (void)dispose(mid);
            if (otp) (void)dispose(otp);
        } else if (!strcmp(command, "CANCEL")) {
            if (active_session) {
                (void)destroy_session(active_session);
                active_session = 0;
            }
            ok_reply();
        } else if (!strcmp(command, "QUIT")) {
            ok_reply();
            break;
        } else {
            error_text("Unknown command");
        }
    }
    if (active_session) (void)destroy_session(active_session);
    (void)no_args(0x08c0fe9e);
    free(line);
    FreeLibrary(module);
    return 0;
}
