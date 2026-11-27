#include "DeviceBridge.h"

#include <ctype.h>
#include <libmtp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *pt_strdup_safe(const char *s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char *copy = (char *)malloc(len + 1);
    if (copy) {
        memcpy(copy, s, len + 1);
    }
    return copy;
}

static void pt_set_error_from_device(LIBMTP_mtpdevice_t *device, const char *fallback, char **out_error) {
    if (!out_error) return;
    if (device) {
        LIBMTP_error_t *err = LIBMTP_Get_Errorstack(device);
        if (err && err->error_text) {
            *out_error = pt_strdup_safe(err->error_text);
            LIBMTP_Clear_Errorstack(device);
            return;
        }
        LIBMTP_Clear_Errorstack(device);
    }
    *out_error = pt_strdup_safe(fallback);
}

static LIBMTP_filetype_t pt_filetype_for_filename(const char *filename) {
    if (!filename) return LIBMTP_FILETYPE_UNKNOWN;
    const char *dot = strrchr(filename, '.');
    if (!dot || dot[1] == '\0') return LIBMTP_FILETYPE_UNKNOWN;

    char ext[32];
    size_t i = 0;
    const char *p = dot + 1;
    while (*p && i < sizeof(ext) - 1) {
        ext[i++] = (char)tolower((unsigned char)*p++);
    }
    ext[i] = '\0';

    if (strcmp(ext, "jpg") == 0 || strcmp(ext, "jpeg") == 0) return LIBMTP_FILETYPE_JPEG;
    if (strcmp(ext, "png") == 0) return LIBMTP_FILETYPE_PNG;
    if (strcmp(ext, "gif") == 0) return LIBMTP_FILETYPE_GIF;
    if (strcmp(ext, "bmp") == 0) return LIBMTP_FILETYPE_BMP;
    if (strcmp(ext, "tif") == 0 || strcmp(ext, "tiff") == 0) return LIBMTP_FILETYPE_TIFF;
    if (strcmp(ext, "mp3") == 0) return LIBMTP_FILETYPE_MP3;
    if (strcmp(ext, "wav") == 0) return LIBMTP_FILETYPE_WAV;
    if (strcmp(ext, "ogg") == 0) return LIBMTP_FILETYPE_OGG;
    if (strcmp(ext, "flac") == 0) return LIBMTP_FILETYPE_FLAC;
    if (strcmp(ext, "aac") == 0) return LIBMTP_FILETYPE_AAC;
    if (strcmp(ext, "m4a") == 0) return LIBMTP_FILETYPE_M4A;
    if (strcmp(ext, "mp4") == 0 || strcmp(ext, "m4v") == 0) return LIBMTP_FILETYPE_MP4;
    if (strcmp(ext, "mov") == 0) return LIBMTP_FILETYPE_QT;
    if (strcmp(ext, "avi") == 0) return LIBMTP_FILETYPE_AVI;
    if (strcmp(ext, "wmv") == 0) return LIBMTP_FILETYPE_WMV;
    if (strcmp(ext, "mpg") == 0 || strcmp(ext, "mpeg") == 0) return LIBMTP_FILETYPE_MPEG;
    if (strcmp(ext, "txt") == 0 || strcmp(ext, "md") == 0 || strcmp(ext, "log") == 0) return LIBMTP_FILETYPE_TEXT;
    if (strcmp(ext, "html") == 0 || strcmp(ext, "htm") == 0) return LIBMTP_FILETYPE_HTML;
    if (strcmp(ext, "xml") == 0) return LIBMTP_FILETYPE_XML;
    if (strcmp(ext, "doc") == 0 || strcmp(ext, "docx") == 0) return LIBMTP_FILETYPE_DOC;
    if (strcmp(ext, "xls") == 0 || strcmp(ext, "xlsx") == 0) return LIBMTP_FILETYPE_XLS;
    if (strcmp(ext, "ppt") == 0 || strcmp(ext, "pptx") == 0) return LIBMTP_FILETYPE_PPT;
    return LIBMTP_FILETYPE_UNKNOWN;
}

typedef struct {
    PTTransferProgressCallback cb;
    void *ctx;
} PTMTPProgressThunk;

static int pt_mtp_progress_adapter(uint64_t const sent, uint64_t const total, void const *const data) {
    if (!data) return 0;
    const PTMTPProgressThunk *thunk = (const PTMTPProgressThunk *)data;
    if (!thunk->cb) return 0;
    return thunk->cb(sent, total, thunk->ctx);
}

void pt_mtp_init(void) {
    static int initialized = 0;
    if (!initialized) {
        LIBMTP_Init();
        initialized = 1;
    }
}

int pt_mtp_detect_devices(PTMTPDeviceInfo **out_devices, int *out_count, char **out_error) {
    if (out_devices) *out_devices = NULL;
    if (out_count) *out_count = 0;
    if (out_error) *out_error = NULL;

    pt_mtp_init();

    LIBMTP_raw_device_t *raw_devices = NULL;
    int num_raw = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&raw_devices, &num_raw);
    if (err == LIBMTP_ERROR_NO_DEVICE_ATTACHED || num_raw <= 0) {
        if (raw_devices) free(raw_devices);
        return 0;
    }
    if (err != LIBMTP_ERROR_NONE) {
        if (raw_devices) free(raw_devices);
        if (out_error) *out_error = pt_strdup_safe("Unable to scan USB MTP devices.");
        return -1;
    }

    PTMTPDeviceInfo *list = (PTMTPDeviceInfo *)calloc((size_t)num_raw, sizeof(PTMTPDeviceInfo));
    if (!list) {
        free(raw_devices);
        return -1;
    }

    for (int i = 0; i < num_raw; i++) {
        list[i].bus_location = raw_devices[i].bus_location;
        list[i].devnum = raw_devices[i].devnum;
        list[i].vendor_id = raw_devices[i].device_entry.vendor_id;
        list[i].product_id = raw_devices[i].device_entry.product_id;
        list[i].vendor_name = pt_strdup_safe(raw_devices[i].device_entry.vendor ? raw_devices[i].device_entry.vendor : "Android");
        list[i].product_name = pt_strdup_safe(raw_devices[i].device_entry.product ? raw_devices[i].device_entry.product : "MTP Device");
    }

    free(raw_devices);
    if (out_devices) *out_devices = list;
    if (out_count) *out_count = num_raw;
    return 0;
}

void pt_mtp_free_devices(PTMTPDeviceInfo *devices, int count) {
    if (!devices) return;
    for (int i = 0; i < count; i++) {
        free(devices[i].vendor_name);
        free(devices[i].product_name);
    }
    free(devices);
}

void *pt_mtp_open(uint32_t bus_location, uint8_t devnum, char **out_friendly_name, char **out_error) {
    if (out_friendly_name) *out_friendly_name = NULL;
    if (out_error) *out_error = NULL;

    pt_mtp_init();

    LIBMTP_raw_device_t *raw_devices = NULL;
    int num_raw = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&raw_devices, &num_raw);
    if (err != LIBMTP_ERROR_NONE || num_raw <= 0) {
        if (raw_devices) free(raw_devices);
        if (out_error) *out_error = pt_strdup_safe("Android MTP device is no longer connected.");
        return NULL;
    }

    int target_idx = -1;
    for (int i = 0; i < num_raw; i++) {
        if (raw_devices[i].bus_location == bus_location && raw_devices[i].devnum == devnum) {
            target_idx = i;
            break;
        }
    }

    if (target_idx < 0) {
        free(raw_devices);
        if (out_error) *out_error = pt_strdup_safe("Android MTP device disconnected or re-enumerated.");
        return NULL;
    }

    LIBMTP_mtpdevice_t *device = LIBMTP_Open_Raw_Device_Uncached(&raw_devices[target_idx]);
    free(raw_devices);

    if (!device) {
        if (out_error) {
            *out_error = pt_strdup_safe(
                "Could not open Android MTP session. Unlock your phone, choose 'File Transfer (MTP)' in USB settings, and close Image Capture, Preview, or Android File Transfer if open."
            );
        }
        return NULL;
    }

    if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0) {
        // Storage may still be empty if phone screen is locked.
        LIBMTP_Clear_Errorstack(device);
    }

    if (out_friendly_name) {
        char *friendly = LIBMTP_Get_Friendlyname(device);
        if (!friendly || strlen(friendly) == 0) {
            free(friendly);
            char *model = LIBMTP_Get_Modelname(device);
            friendly = model;
        }
        *out_friendly_name = friendly ? friendly : pt_strdup_safe("Android Device");
    }

    return (void *)device;
}

void pt_mtp_close(void *handle) {
    if (!handle) return;
    LIBMTP_mtpdevice_t *device = (LIBMTP_mtpdevice_t *)handle;
    LIBMTP_Release_Device(device);
}

int pt_mtp_get_storages(void *handle, PTMTPStorageInfo **out_storages, int *out_count, char **out_error) {
    if (out_storages) *out_storages = NULL;
    if (out_count) *out_count = 0;
    if (out_error) *out_error = NULL;
    if (!handle) return -1;

    LIBMTP_mtpdevice_t *device = (LIBMTP_mtpdevice_t *)handle;
    if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) < 0) {
        pt_set_error_from_device(device, "Unlock your Android phone and select 'File Transfer' to access storage.", out_error);
        return -1;
    }

    int count = 0;
    for (LIBMTP_devicestorage_t *s = device->storage; s != NULL; s = s->next) {
        count++;
    }
    if (count == 0) {
        if (out_error) *out_error = pt_strdup_safe("No MTP storage exposed. Unlock phone and switch USB mode to 'File Transfer'.");
        return 0;
    }

    PTMTPStorageInfo *list = (PTMTPStorageInfo *)calloc((size_t)count, sizeof(PTMTPStorageInfo));
    if (!list) return -1;

    int idx = 0;
    for (LIBMTP_devicestorage_t *s = device->storage; s != NULL; s = s->next) {
        list[idx].storage_id = s->id;
        list[idx].description = pt_strdup_safe(s->StorageDescription ? s->StorageDescription : "Internal Storage");
        list[idx].max_capacity = s->MaxCapacity;
        list[idx].free_space = s->FreeSpaceInBytes;
        idx++;
    }

    if (out_storages) *out_storages = list;
    if (out_count) *out_count = count;
    return 0;
}

void pt_mtp_free_storages(PTMTPStorageInfo *storages, int count) {
    if (!storages) return;
    for (int i = 0; i < count; i++) {
        free(storages[i].description);
    }
    free(storages);
}

int pt_mtp_list_folder(
    void *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    PTMTPItem **out_items,
    int *out_count,
    char **out_error
) {
    if (out_items) *out_items = NULL;
    if (out_count) *out_count = 0;
    if (out_error) *out_error = NULL;
    if (!handle) return -1;

    LIBMTP_mtpdevice_t *device = (LIBMTP_mtpdevice_t *)handle;
    uint32_t query_parent = (parent_id == 0) ? LIBMTP_FILES_AND_FOLDERS_ROOT : parent_id;

    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(device, storage_id, query_parent);
    if (!files) {
        LIBMTP_error_t *err = LIBMTP_Get_Errorstack(device);
        if (err && err->errornumber != LIBMTP_ERROR_NONE) {
            pt_set_error_from_device(device, "Failed to list MTP folder.", out_error);
            return -1;
        }
        LIBMTP_Clear_Errorstack(device);
        return 0;
    }

    int count = 0;
    for (LIBMTP_file_t *f = files; f != NULL; f = f->next) {
        count++;
    }

    PTMTPItem *list = (PTMTPItem *)calloc((size_t)count, sizeof(PTMTPItem));
    if (!list) {
        LIBMTP_file_t *cur = files;
        while (cur) {
            LIBMTP_file_t *next = cur->next;
            LIBMTP_destroy_file_t(cur);
            cur = next;
        }
        return -1;
    }

    int idx = 0;
    LIBMTP_file_t *cur = files;
    while (cur) {
        LIBMTP_file_t *next = cur->next;
        list[idx].item_id = cur->item_id;
        list[idx].parent_id = cur->parent_id;
        list[idx].storage_id = cur->storage_id;
        list[idx].name = pt_strdup_safe(cur->filename ? cur->filename : "Unnamed");
        list[idx].size = cur->filesize;
        list[idx].modified_timestamp = (int64_t)cur->modificationdate;
        list[idx].is_folder = (cur->filetype == LIBMTP_FILETYPE_FOLDER);
        LIBMTP_destroy_file_t(cur);
        cur = next;
        idx++;
    }

    if (out_items) *out_items = list;
    if (out_count) *out_count = count;
    return 0;
}

void pt_mtp_free_items(PTMTPItem *items, int count) {
    if (!items) return;
    for (int i = 0; i < count; i++) {
        free(items[i].name);
    }
    free(items);
}

int pt_mtp_create_folder(
    void *handle,
    uint32_t storage_id,
    uint32_t parent_id,
    const char *name,
    uint32_t *out_folder_id,
    char **out_error
) {
    if (out_folder_id) *out_folder_id = 0;
    if (out_error) *out_error = NULL;
    if (!handle || !name) return -1;

    LIBMTP_mtpdevice_t *device = (LIBMTP_mtpdevice_t *)handle;
    char *mutable_name = pt_strdup_safe(name);
    if (!mutable_name) return -1;

    uint32_t created = LIBMTP_Create_Folder(device, mutable_name, parent_id, storage_id);
    free(mutable_name);

    if (created == 0) {
        pt_set_error_from_device(device, "Failed to create folder on Android device.", out_error);
        return -1;
    }
    if (out_folder_id) *out_folder_id = created;
    return 0;
}

int pt_mtp_delete_object(void *handle, uint32_t object_id, char **out_error) {
    if (out_error) *out_error = NULL;
    if (!handle) return -1;

    LIBMTP_mtpdevice_t *device = (LIBMTP_mtpdevice_t *)handle;
    if (LIBMTP_Delete_Object(device, object_id) != 0) {
        pt_set_error_from_device(device, "Failed to delete item on Android device.", out_error);
        return -1;
    }
    return 0;
}

int pt_mtp_rename_object(void *handle, uint32_t object_id, const char *new_name, char **out_error) {
    if (out_error) *out_error = NULL;
    if (!handle || !new_name) return -1;

    LIBMTP_mtpdevice_t *device = (LIBMTP_mtpdevice_t *)handle;
    char *mutable_name = pt_strdup_safe(new_name);
    if (!mutable_name) return -1;

    int res = LIBMTP_Set_Object_Filename(device, object_id, mutable_name);
    free(mutable_name);

    if (res != 0) {
        pt_set_error_from_device(device, "Failed to rename item on Android device.", out_error);
        return -1;
    }
    return 0;
}

int pt_mtp_download_file(
    void *handle,
    uint32_t object_id,
    const char *local_path,
    PTTransferProgressCallback callback,
    void *context,
    char **out_error
) {
    if (out_error) *out_error = NULL;
    if (!handle || !local_path) return -1;

    LIBMTP_mtpdevice_t *device = (LIBMTP_mtpdevice_t *)handle;
    PTMTPProgressThunk thunk = { callback, context };
    int res = LIBMTP_Get_File_To_File(
        device,
        object_id,
        local_path,
        callback ? pt_mtp_progress_adapter : NULL,
        callback ? &thunk : NULL
    );

    if (res != 0) {
        pt_set_error_from_device(device, "Failed to download file from Android device.", out_error);
        return -1;
    }
    return 0;
}

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
) {
    if (out_object_id) *out_object_id = 0;
    if (out_error) *out_error = NULL;
    if (!handle || !local_path || !filename) return -1;

    LIBMTP_mtpdevice_t *device = (LIBMTP_mtpdevice_t *)handle;
    LIBMTP_file_t *meta = LIBMTP_new_file_t();
    if (!meta) return -1;

    meta->filename = pt_strdup_safe(filename);
    meta->filesize = filesize;
    meta->parent_id = parent_id;
    meta->storage_id = storage_id;
    meta->filetype = pt_filetype_for_filename(filename);

    PTMTPProgressThunk thunk = { callback, context };
    int res = LIBMTP_Send_File_From_File(
        device,
        local_path,
        meta,
        callback ? pt_mtp_progress_adapter : NULL,
        callback ? &thunk : NULL
    );

    uint32_t created_id = meta->item_id;
    LIBMTP_destroy_file_t(meta);

    if (res != 0) {
        pt_set_error_from_device(device, "Failed to upload file to Android device.", out_error);
        return -1;
    }
    if (out_object_id) *out_object_id = created_id;
    return 0;
}

void pt_free_string(char *str) {
    free(str);
}
