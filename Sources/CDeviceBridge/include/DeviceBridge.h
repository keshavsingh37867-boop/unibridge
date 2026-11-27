#ifndef DEVICE_BRIDGE_H
#define DEVICE_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Android MTP (libmtp)

typedef struct {
    uint32_t bus_location;
    uint8_t devnum;
    uint16_t vendor_id;
    uint16_t product_id;
    char *vendor_name;
    char *product_name;
} PTMTPDeviceInfo;

typedef struct {
    uint32_t storage_id;
    char *description;
    uint64_t max_capacity;
    uint64_t free_space;
} PTMTPStorageInfo;

typedef struct {
    uint32_t item_id;
    uint32_t parent_id;
    uint32_t storage_id;
    char *name;
    uint64_t size;
    int64_t modified_timestamp;
    bool is_folder;
} PTMTPItem;

/// Return 0 to continue, non-zero to cancel transfer.
typedef int (*PTTransferProgressCallback)(uint64_t transferred, uint64_t total, void *context);

void pt_mtp_init(void);

int pt_mtp_detect_devices(PTMTPDeviceInfo **out_devices, int *out_count, char **out_error);
void pt_mtp_free_devices(PTMTPDeviceInfo *devices, int count);

void *pt_mtp_open(uint32_t bus_location, uint8_t devnum, char **out_friendly_name, char **out_error);
void pt_mtp_close(void *handle);

int pt_mtp_get_storages(void *handle, PTMTPStorageInfo **out_storages, int *out_count, char **out_error);
void pt_mtp_free_storages(PTMTPStorageInfo *storages, int count);

int pt_mtp_list_folder(
    void *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    PTMTPItem **out_items,
    int *out_count,
    char **out_error
);
void pt_mtp_free_items(PTMTPItem *items, int count);

int pt_mtp_create_folder(
    void *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    uint32_t *out_folder_id,
    char **out_error
);

int pt_mtp_delete_object(void *handle, uint32_t object_id, char **out_error);
int pt_mtp_rename_object(void *handle, uint32_t object_id, const char *new_name, char **out_error);

int pt_mtp_download_file(
    void *handle,
    uint32_t object_id,
    const char *local_path,
    PTTransferProgressCallback callback,
    void *context,
    char **out_error
);

int pt_mtp_upload_file(
    void *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *local_path,
    const char *filename,
    uint64_t filesize,
    PTTransferProgressCallback callback,
    void *context,
    uint32_t *out_object_id,
    char **out_error
);

// MARK: - iOS (libimobiledevice AFC + House Arrest)

typedef struct {
    char *udid;
    char *device_name;
    char *product_type;
    char *product_version;
    char *device_class;
    bool is_usb;
    bool is_paired;
    char *status_message;
} PTIOSDeviceInfo;

typedef struct {
    char *bundle_id;
    char *display_name;
} PTIOSAppInfo;

typedef struct {
    char *name;
    uint64_t size;
    int64_t modified_timestamp;
    bool is_directory;
} PTIOSFileEntry;

typedef void (*PTIOSEventCallback)(int event_type, const char *udid, void *context);

void *pt_ios_subscribe_events(PTIOSEventCallback callback, void *context);
void pt_ios_unsubscribe_events(void *subscription);

int pt_ios_list_devices(PTIOSDeviceInfo **out_devices, int *out_count);
void pt_ios_free_devices(PTIOSDeviceInfo *devices, int count);

int pt_ios_list_file_sharing_apps(const char *udid, PTIOSAppInfo **out_apps, int *out_count, char **out_error);
void pt_ios_free_apps(PTIOSAppInfo *apps, int count);

int pt_ios_get_storage_info(
    const char *udid,
    const char *app_bundle_id,
    uint64_t *out_total,
    uint64_t *out_free,
    char **out_error
);

int pt_ios_list_directory(
    const char *udid,
    const char *app_bundle_id,
    const char *remote_path,
    PTIOSFileEntry **out_entries,
    int *out_count,
    char **out_error
);
void pt_ios_free_entries(PTIOSFileEntry *entries, int count);

int pt_ios_create_directory(
    const char *udid,
    const char *app_bundle_id,
    const char *remote_path,
    char **out_error
);

int pt_ios_rename_path(
    const char *udid,
    const char *app_bundle_id,
    const char *from_path,
    const char *to_path,
    char **out_error
);

int pt_ios_delete_path(
    const char *udid,
    const char *app_bundle_id,
    const char *remote_path,
    char **out_error
);

int pt_ios_download_file(
    const char *udid,
    const char *app_bundle_id,
    const char *remote_path,
    const char *local_path,
    uint64_t expected_size,
    PTTransferProgressCallback callback,
    void *context,
    char **out_error
);

int pt_ios_upload_file(
    const char *udid,
    const char *app_bundle_id,
    const char *local_path,
    const char *remote_path,
    uint64_t filesize,
    PTTransferProgressCallback callback,
    void *context,
    char **out_error
);

void pt_free_string(char *str);

#ifdef __cplusplus
}
#endif

#endif
