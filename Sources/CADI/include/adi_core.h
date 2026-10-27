/* C ABI from sacca97/os-findmy-e native/adi-core, MIT license.
 * https://github.com/sacca97/os-findmy-e/blob/main/native/adi-core/adi_core.h
 * The Rust implementation is built separately and linked as libadi_core.so.
 */
#ifndef ADI_CORE_H
#define ADI_CORE_H
#include <stddef.h>
#include <stdint.h>

#define ADI_OK 0
#define ADI_ERR -1
#define ADI_ERR_NOT_PROVISIONED -2
#define ADI_ERR_ALREADY_PROVISIONED -3

typedef struct AdiHandle AdiHandle;
typedef struct { uint8_t *ptr; size_t len; } AdiBuf;

int32_t adi_open(const uint8_t *image, size_t len, AdiHandle **out);
void adi_close(AdiHandle *h);
size_t adi_build_name(AdiHandle *h, char *buf, size_t cap);
size_t adi_last_error(char *buf, size_t cap);
void adi_buf_free(AdiBuf b);

int32_t adi_set_host_uuid(AdiHandle *h, const uint8_t uuid[16]);
int32_t adi_set_frozen_time(AdiHandle *h, int64_t secs);
int32_t adi_store_put(AdiHandle *h, const char *name, const uint8_t *data, size_t len);
int32_t adi_store_export(AdiHandle *h, AdiBuf *out);
int32_t adi_store_import(AdiHandle *h, const uint8_t *data, size_t len);

int32_t adi_headers(AdiHandle *h, int64_t ds_id, AdiBuf *mid, AdiBuf *otp, uint64_t *routing);
int32_t adi_provisioning_begin(AdiHandle *h, int64_t ds_id, const uint8_t *spim, size_t spim_len,
                               AdiBuf *cpim, uint32_t *session);
int32_t adi_provisioning_finish(AdiHandle *h, int64_t ds_id, uint32_t session, const uint8_t *ptm,
                                size_t ptm_len, const uint8_t *tk, size_t tk_len, uint64_t routing);
int32_t adi_sync(AdiHandle *h, int64_t ds_id, const uint8_t *sim, size_t sim_len,
                 AdiBuf *mid, AdiBuf *srm);
int32_t adi_update_routing(AdiHandle *h, int64_t ds_id, uint64_t routing);
#endif
