#include "DeviceBridge.h"

#include <errno.h>
#include <libimobiledevice/afc.h>
#include <libimobiledevice/house_arrest.h>
#include <libimobiledevice/installation_proxy.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <plist/plist.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *ios_strdup_safe(const char *s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char *copy = (char *)malloc(len + 1);
    if (copy) {
        memcpy(copy, s, len + 1);
    }
    return copy;
}

static void ios_set_error(char **out_error, const char *msg) {
    if (!out_error) return;
    *out_error = ios_strdup_safe(msg);
}

static char *plist_read_string(plist_t node) {
    if (!node || plist_get_node_type(node) != PLIST_STRING) return NULL;
    char *val = NULL;
    plist_get_string_val(node, &val);
    return val;
}

static uint64_t plist_read_uint64(plist_t node) {
    if (!node) return 0;
    plist_type t = plist_get_node_type(node);
    if (t == PLIST_INT) {
        uint64_t v = 0;
        plist_get_uint_val(node, &v);
        return v;
    }
    if (t == PLIST_STRING) {
        char *s = NULL;
        plist_get_string_val(node, &s);
        uint64_t v = 0;
        if (s) {
            v = strtoull(s, NULL, 10);
            free(s);
        }
        return v;
    }
    return 0;
}

static bool plist_read_bool(plist_t node) {
    if (!node) return false;
    plist_type t = plist_get_node_type(node);
    if (t == PLIST_BOOLEAN) {
        uint8_t b = 0;
        plist_get_bool_val(node, &b);
        return b != 0;
    }
    if (t == PLIST_STRING) {
        char *s = NULL;
        plist_get_string_val(node, &s);
        bool result = (s && (strcmp(s, "true") == 0 || strcmp(s, "1") == 0));
        free(s);
        return result;
    }
    return false;
}

typedef struct {
    PTIOSEventCallback cb;
    void *ctx;
    idevice_subscription_context_t sub;
} PTIOSSubscriptionBox;

static void ios_event_adapter(const idevice_event_t *event, void *user_data) {
    if (!event || !user_data) return;
    PTIOSSubscriptionBox *box = (PTIOSSubscriptionBox *)user_data;
    if (box->cb) {
        box->cb((int)event->event, event->udid, box->ctx);
    }
}

void *pt_ios_subscribe_events(PTIOSEventCallback callback, void *context) {
    PTIOSSubscriptionBox *box = (PTIOSSubscriptionBox *)calloc(1, sizeof(PTIOSSubscriptionBox));
    if (!box) return NULL;
    box->cb = callback;
    box->ctx = context;

    if (idevice_events_subscribe(&box->sub, ios_event_adapter, box) != IDEVICE_E_SUCCESS) {
        free(box);
        return NULL;
    }
    return box;
}

void pt_ios_unsubscribe_events(void *subscription) {
    if (!subscription) return;
    PTIOSSubscriptionBox *box = (PTIOSSubscriptionBox *)subscription;
    if (box->sub) {
        idevice_events_unsubscribe(box->sub);
    }
    free(box);
}

int pt_ios_list_devices(PTIOSDeviceInfo **out_devices, int *out_count) {
    if (out_devices) *out_devices = NULL;
    if (out_count) *out_count = 0;

    idevice_info_t *dev_list = NULL;
    int count = 0;
    if (idevice_get_device_list_extended(&dev_list, &count) != IDEVICE_E_SUCCESS || count <= 0) {
        if (dev_list) idevice_device_list_extended_free(dev_list);
        return 0;
    }

    // Deduplicate UDIDs, preferring USB connections over network connections.
    PTIOSDeviceInfo *results = (PTIOSDeviceInfo *)calloc((size_t)count, sizeof(PTIOSDeviceInfo));
    if (!results) {
        idevice_device_list_extended_free(dev_list);
        return -1;
    }

    int out_idx = 0;
    for (int i = 0; i < count; i++) {
        const char *udid = dev_list[i]->udid;
        if (!udid) continue;

        bool is_usb = (dev_list[i]->conn_type == CONNECTION_USBMUXD);
        int existing = -1;
        for (int j = 0; j < out_idx; j++) {
            if (strcmp(results[j].udid, udid) == 0) {
                existing = j;
                break;
            }
        }
        if (existing >= 0) {
            if (is_usb) results[existing].is_usb = true;
            continue;
        }

        results[out_idx].udid = ios_strdup_safe(udid);
        results[out_idx].is_usb = is_usb;

        idevice_t dev = NULL;
        enum idevice_options opts = is_usb ? IDEVICE_LOOKUP_USBMUX : IDEVICE_LOOKUP_NETWORK;
        if (idevice_new_with_options(&dev, udid, opts) == IDEVICE_E_SUCCESS && dev) {
            lockdownd_client_t lockdown = NULL;
            lockdownd_error_t lerr = lockdownd_client_new_with_handshake(dev, &lockdown, "PendriveTransfer");
            if (lerr == LOCKDOWN_E_SUCCESS && lockdown) {
                results[out_idx].is_paired = true;

                plist_t name_node = NULL;
                if (lockdownd_get_value(lockdown, NULL, "DeviceName", &name_node) == LOCKDOWN_E_SUCCESS && name_node) {
                    results[out_idx].device_name = plist_read_string(name_node);
                    plist_free(name_node);
                }

                plist_t type_node = NULL;
                if (lockdownd_get_value(lockdown, NULL, "ProductType", &type_node) == LOCKDOWN_E_SUCCESS && type_node) {
                    results[out_idx].product_type = plist_read_string(type_node);
                    plist_free(type_node);
                }

                plist_t ver_node = NULL;
                if (lockdownd_get_value(lockdown, NULL, "ProductVersion", &ver_node) == LOCKDOWN_E_SUCCESS && ver_node) {
                    results[out_idx].product_version = plist_read_string(ver_node);
                    plist_free(ver_node);
                }

                plist_t class_node = NULL;
                if (lockdownd_get_value(lockdown, NULL, "DeviceClass", &class_node) == LOCKDOWN_E_SUCCESS && class_node) {
                    results[out_idx].device_class = plist_read_string(class_node);
                    plist_free(class_node);
                }

                lockdownd_client_free(lockdown);
            } else {
                results[out_idx].is_paired = false;
                if (lerr == LOCKDOWN_E_PASSWORD_PROTECTED) {
                    results[out_idx].status_message = ios_strdup_safe("Unlock your iPhone/iPad with its passcode, then tap Rescan.");
                } else if (lerr == LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING || lerr == LOCKDOWN_E_USER_DENIED_PAIRING || lerr == LOCKDOWN_E_INVALID_CONF) {
                    results[out_idx].status_message = ios_strdup_safe("Tap 'Trust This Computer' on your iPhone/iPad, then tap Rescan.");
                } else {
                    results[out_idx].status_message = ios_strdup_safe("Unlock your iPhone/iPad and trust this Mac to browse files.");
                }

                // Best-effort unencrypted query for device name/class when unpaired.
                lockdownd_client_t plain_client = NULL;
                if (lockdownd_client_new(dev, &plain_client, "PendriveTransfer") == LOCKDOWN_E_SUCCESS && plain_client) {
                    plist_t name_node = NULL;
                    if (lockdownd_get_value(plain_client, NULL, "DeviceName", &name_node) == LOCKDOWN_E_SUCCESS && name_node) {
                        results[out_idx].device_name = plist_read_string(name_node);
                        plist_free(name_node);
                    }
                    plist_t class_node = NULL;
                    if (lockdownd_get_value(plain_client, NULL, "DeviceClass", &class_node) == LOCKDOWN_E_SUCCESS && class_node) {
                        results[out_idx].device_class = plist_read_string(class_node);
                        plist_free(class_node);
                    }
                    lockdownd_client_free(plain_client);
                }
            }
            idevice_free(dev);
        }

        if (!results[out_idx].device_name) {
            results[out_idx].device_name = ios_strdup_safe(results[out_idx].device_class ? results[out_idx].device_class : "iOS Device");
        }
        out_idx++;
    }

    idevice_device_list_extended_free(dev_list);
    if (out_devices) *out_devices = results;
    if (out_count) *out_count = out_idx;
    return 0;
}

void pt_ios_free_devices(PTIOSDeviceInfo *devices, int count) {
    if (!devices) return;
    for (int i = 0; i < count; i++) {
        free(devices[i].udid);
        free(devices[i].device_name);
        free(devices[i].product_type);
        free(devices[i].product_version);
        free(devices[i].device_class);
        free(devices[i].status_message);
    }
    free(devices);
}

int pt_ios_list_file_sharing_apps(const char *udid, PTIOSAppInfo **out_apps, int *out_count, char **out_error) {
    if (out_apps) *out_apps = NULL;
    if (out_count) *out_count = 0;
    if (out_error) *out_error = NULL;
    if (!udid) return -1;

    idevice_t dev = NULL;
    if (idevice_new_with_options(&dev, udid, IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK) != IDEVICE_E_SUCCESS || !dev) {
        ios_set_error(out_error, "iOS device is not reachable.");
        return -1;
    }

    instproxy_client_t inst = NULL;
    if (instproxy_client_start_service(dev, &inst, "PendriveTransfer") != INSTPROXY_E_SUCCESS || !inst) {
        idevice_free(dev);
        ios_set_error(out_error, "Could not query installed iOS apps.");
        return -1;
    }

    plist_t opts = plist_new_dict();
    plist_dict_set_item(opts, "ApplicationType", plist_new_string("User"));

    plist_t apps_plist = NULL;
    instproxy_error_t ierr = instproxy_browse(inst, opts, &apps_plist);
    plist_free(opts);
    instproxy_client_free(inst);
    idevice_free(dev);

    if (ierr != INSTPROXY_E_SUCCESS || !apps_plist || plist_get_node_type(apps_plist) != PLIST_ARRAY) {
        if (apps_plist) plist_free(apps_plist);
        ios_set_error(out_error, "Failed to list iOS apps.");
        return -1;
    }

    uint32_t total = plist_array_get_size(apps_plist);
    PTIOSAppInfo *list = (PTIOSAppInfo *)calloc(total > 0 ? total : 1, sizeof(PTIOSAppInfo));
    if (!list) {
        plist_free(apps_plist);
        return -1;
    }

    int out_idx = 0;
    for (uint32_t i = 0; i < total; i++) {
        plist_t app = plist_array_get_item(apps_plist, i);
        if (!app || plist_get_node_type(app) != PLIST_DICT) continue;

        plist_t sharing_node = plist_dict_get_item(app, "UIFileSharingEnabled");
        if (!plist_read_bool(sharing_node)) {
            continue;
        }

        char *bundle_id = plist_read_string(plist_dict_get_item(app, "CFBundleIdentifier"));
        if (!bundle_id) continue;

        char *display_name = plist_read_string(plist_dict_get_item(app, "CFBundleDisplayName"));
        if (!display_name) {
            display_name = plist_read_string(plist_dict_get_item(app, "CFBundleName"));
        }
        if (!display_name) {
            display_name = ios_strdup_safe(bundle_id);
        }

        list[out_idx].bundle_id = bundle_id;
        list[out_idx].display_name = display_name;
        out_idx++;
    }

    plist_free(apps_plist);
    if (out_idx == 0) {
        free(list);
        return 0;
    }

    if (out_apps) *out_apps = list;
    if (out_count) *out_count = out_idx;
    return 0;
}

void pt_ios_free_apps(PTIOSAppInfo *apps, int count) {
    if (!apps) return;
    for (int i = 0; i < count; i++) {
        free(apps[i].bundle_id);
        free(apps[i].display_name);
    }
    free(apps);
}

typedef struct {
    idevice_t dev;
    house_arrest_client_t house_arrest;
    afc_client_t afc;
} PTIOSAFCSession;

static int ios_open_afc_session(
    const char *udid,
    const char *app_bundle_id,
    PTIOSAFCSession *out_session,
    char **out_error
) {
    memset(out_session, 0, sizeof(*out_session));
    if (!udid) {
        ios_set_error(out_error, "Missing iOS device UDID.");
        return -1;
    }

    if (idevice_new_with_options(&out_session->dev, udid, IDEVICE_LOOKUP_USBMUX | IDEVICE_LOOKUP_NETWORK) != IDEVICE_E_SUCCESS || !out_session->dev) {
        ios_set_error(out_error, "iOS device disconnected.");
        return -1;
    }

    if (app_bundle_id && strlen(app_bundle_id) > 0) {
        if (house_arrest_client_start_service(out_session->dev, &out_session->house_arrest, "PendriveTransfer") != HOUSE_ARREST_E_SUCCESS || !out_session->house_arrest) {
            idevice_free(out_session->dev);
            out_session->dev = NULL;
            ios_set_error(out_error, "Could not start iOS App File Sharing (House Arrest) service. Ensure device is trusted.");
            return -1;
        }

        if (house_arrest_send_command(out_session->house_arrest, "VendDocuments", app_bundle_id) != HOUSE_ARREST_E_SUCCESS) {
            house_arrest_client_free(out_session->house_arrest);
            idevice_free(out_session->dev);
            memset(out_session, 0, sizeof(*out_session));
            ios_set_error(out_error, "Failed to access app container on iOS device.");
            return -1;
        }

        plist_t result = NULL;
        if (house_arrest_get_result(out_session->house_arrest, &result) != HOUSE_ARREST_E_SUCCESS || !result) {
            if (result) plist_free(result);
            house_arrest_client_free(out_session->house_arrest);
            idevice_free(out_session->dev);
            memset(out_session, 0, sizeof(*out_session));
            ios_set_error(out_error, "App rejected file sharing request.");
            return -1;
        }

        char *status = plist_read_string(plist_dict_get_item(result, "Status"));
        char *err_str = plist_read_string(plist_dict_get_item(result, "Error"));
        plist_free(result);

        if (!status || strcmp(status, "Complete") != 0) {
            ios_set_error(out_error, err_str ? err_str : "This app does not allow USB file sharing.");
            free(status);
            free(err_str);
            house_arrest_client_free(out_session->house_arrest);
            idevice_free(out_session->dev);
            memset(out_session, 0, sizeof(*out_session));
            return -1;
        }
        free(status);
        free(err_str);

        if (afc_client_new_from_house_arrest_client(out_session->house_arrest, &out_session->afc) != AFC_E_SUCCESS || !out_session->afc) {
            house_arrest_client_free(out_session->house_arrest);
            idevice_free(out_session->dev);
            memset(out_session, 0, sizeof(*out_session));
            ios_set_error(out_error, "Could not open app document channel.");
            return -1;
        }
    } else {
        if (afc_client_start_service(out_session->dev, &out_session->afc, "PendriveTransfer") != AFC_E_SUCCESS || !out_session->afc) {
            idevice_free(out_session->dev);
            out_session->dev = NULL;
            ios_set_error(out_error, "Could not open iOS Media (AFC) service. Unlock iPhone/iPad and tap 'Trust This Computer'.");
            return -1;
        }
    }

    return 0;
}

static void ios_close_afc_session(PTIOSAFCSession *session) {
    if (!session) return;
    if (session->afc) {
        afc_client_free(session->afc);
        session->afc = NULL;
    }
    if (session->house_arrest) {
        house_arrest_client_free(session->house_arrest);
        session->house_arrest = NULL;
    }
    if (session->dev) {
        idevice_free(session->dev);
        session->dev = NULL;
    }
}

int pt_ios_get_storage_info(
    const char *udid,
    const char *app_bundle_id,
    uint64_t *out_total,
    uint64_t *out_free,
    char **out_error
) {
    if (out_total) *out_total = 0;
    if (out_free) *out_free = 0;
    if (out_error) *out_error = NULL;

    PTIOSAFCSession session;
    if (ios_open_afc_session(udid, app_bundle_id, &session, out_error) != 0) {
        return -1;
    }

    plist_t info = NULL;
    if (afc_get_device_info_plist(session.afc, &info) == AFC_E_SUCCESS && info) {
        if (out_total) *out_total = plist_read_uint64(plist_dict_get_item(info, "FSTotalBytes"));
        if (out_free) *out_free = plist_read_uint64(plist_dict_get_item(info, "FSFreeBytes"));
        plist_free(info);
    }

    ios_close_afc_session(&session);
    return 0;
}

int pt_ios_list_directory(
    const char *udid,
    const char *app_bundle_id,
    const char *remote_path,
    PTIOSFileEntry **out_entries,
    int *out_count,
    char **out_error
) {
    if (out_entries) *out_entries = NULL;
    if (out_count) *out_count = 0;
    if (out_error) *out_error = NULL;

    PTIOSAFCSession session;
    if (ios_open_afc_session(udid, app_bundle_id, &session, out_error) != 0) {
        return -1;
    }

    const char *dir_path = (remote_path && strlen(remote_path) > 0) ? remote_path : "/";
    char **names = NULL;
    afc_error_t err = afc_read_directory(session.afc, dir_path, &names);
    if (err != AFC_E_SUCCESS || !names) {
        ios_set_error(out_error, afc_strerror(err));
        ios_close_afc_session(&session);
        return -1;
    }

    int capacity = 0;
    for (int i = 0; names[i] != NULL; i++) {
        if (strcmp(names[i], ".") == 0 || strcmp(names[i], "..") == 0) continue;
        capacity++;
    }

    PTIOSFileEntry *entries = (PTIOSFileEntry *)calloc(capacity > 0 ? (size_t)capacity : 1, sizeof(PTIOSFileEntry));
    if (!entries) {
        afc_dictionary_free(names);
        ios_close_afc_session(&session);
        return -1;
    }

    int idx = 0;
    for (int i = 0; names[i] != NULL; i++) {
        const char *name = names[i];
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;

        size_t full_len = strlen(dir_path) + strlen(name) + 2;
        char *full_path = (char *)malloc(full_len);
        if (!full_path) continue;
        if (strcmp(dir_path, "/") == 0) {
            snprintf(full_path, full_len, "/%s", name);
        } else {
            snprintf(full_path, full_len, "%s/%s", dir_path, name);
        }

        plist_t info = NULL;
        bool is_dir = false;
        uint64_t fsize = 0;
        int64_t mtime_sec = 0;

        if (afc_get_file_info_plist(session.afc, full_path, &info) == AFC_E_SUCCESS && info) {
            char *ifmt = plist_read_string(plist_dict_get_item(info, "st_ifmt"));
            if (ifmt) {
                is_dir = (strcmp(ifmt, "S_IFDIR") == 0);
                free(ifmt);
            }
            fsize = plist_read_uint64(plist_dict_get_item(info, "st_size"));
            uint64_t mtime_ns = plist_read_uint64(plist_dict_get_item(info, "st_mtime"));
            if (mtime_ns > 1000000000000ULL) {
                mtime_sec = (int64_t)(mtime_ns / 1000000000ULL);
            } else {
                mtime_sec = (int64_t)mtime_ns;
            }
            plist_free(info);
        }

        free(full_path);

        entries[idx].name = ios_strdup_safe(name);
        entries[idx].size = is_dir ? 0 : fsize;
        entries[idx].modified_timestamp = mtime_sec;
        entries[idx].is_directory = is_dir;
        idx++;
    }

    afc_dictionary_free(names);
    ios_close_afc_session(&session);

    if (idx == 0) {
        free(entries);
        return 0;
    }

    if (out_entries) *out_entries = entries;
    if (out_count) *out_count = idx;
    return 0;
}

void pt_ios_free_entries(PTIOSFileEntry *entries, int count) {
    if (!entries) return;
    for (int i = 0; i < count; i++) {
        free(entries[i].name);
    }
    free(entries);
}

int pt_ios_create_directory(
    const char *udid,
    const char *app_bundle_id,
    const char *remote_path,
    char **out_error
) {
    if (out_error) *out_error = NULL;
    PTIOSAFCSession session;
    if (ios_open_afc_session(udid, app_bundle_id, &session, out_error) != 0) {
        return -1;
    }
    afc_error_t err = afc_make_directory(session.afc, remote_path);
    ios_close_afc_session(&session);
    if (err != AFC_E_SUCCESS) {
        ios_set_error(out_error, afc_strerror(err));
        return -1;
    }
    return 0;
}

int pt_ios_rename_path(
    const char *udid,
    const char *app_bundle_id,
    const char *from_path,
    const char *to_path,
    char **out_error
) {
    if (out_error) *out_error = NULL;
    PTIOSAFCSession session;
    if (ios_open_afc_session(udid, app_bundle_id, &session, out_error) != 0) {
        return -1;
    }
    afc_error_t err = afc_rename_path(session.afc, from_path, to_path);
    ios_close_afc_session(&session);
    if (err != AFC_E_SUCCESS) {
        ios_set_error(out_error, afc_strerror(err));
        return -1;
    }
    return 0;
}

int pt_ios_delete_path(
    const char *udid,
    const char *app_bundle_id,
    const char *remote_path,
    char **out_error
) {
    if (out_error) *out_error = NULL;
    PTIOSAFCSession session;
    if (ios_open_afc_session(udid, app_bundle_id, &session, out_error) != 0) {
        return -1;
    }
    afc_error_t err = afc_remove_path_and_contents(session.afc, remote_path);
    if (err != AFC_E_SUCCESS) {
        err = afc_remove_path(session.afc, remote_path);
    }
    ios_close_afc_session(&session);
    if (err != AFC_E_SUCCESS) {
        ios_set_error(out_error, afc_strerror(err));
        return -1;
    }
    return 0;
}

int pt_ios_download_file(
    const char *udid,
    const char *app_bundle_id,
    const char *remote_path,
    const char *local_path,
    uint64_t expected_size,
    PTTransferProgressCallback callback,
    void *context,
    char **out_error
) {
    if (out_error) *out_error = NULL;
    PTIOSAFCSession session;
    if (ios_open_afc_session(udid, app_bundle_id, &session, out_error) != 0) {
        return -1;
    }

    uint64_t handle = 0;
    afc_error_t err = afc_file_open(session.afc, remote_path, AFC_FOPEN_RDONLY, &handle);
    if (err != AFC_E_SUCCESS) {
        ios_set_error(out_error, afc_strerror(err));
        ios_close_afc_session(&session);
        return -1;
    }

    FILE *fp = fopen(local_path, "wb");
    if (!fp) {
        afc_file_close(session.afc, handle);
        ios_close_afc_session(&session);
        ios_set_error(out_error, strerror(errno));
        return -1;
    }

    const uint32_t buf_size = 524288; // 512 KB chunks
    char *buf = (char *)malloc(buf_size);
    if (!buf) {
        fclose(fp);
        afc_file_close(session.afc, handle);
        ios_close_afc_session(&session);
        ios_set_error(out_error, "Out of memory.");
        return -1;
    }

    uint64_t total_read = 0;
    int status = 0;

    while (1) {
        uint32_t bytes_read = 0;
        err = afc_file_read(session.afc, handle, buf, buf_size, &bytes_read);
        if (err != AFC_E_SUCCESS) {
            ios_set_error(out_error, afc_strerror(err));
            status = -1;
            break;
        }
        if (bytes_read == 0) {
            break;
        }
        if (fwrite(buf, 1, bytes_read, fp) != bytes_read) {
            ios_set_error(out_error, strerror(errno));
            status = -1;
            break;
        }
        total_read += bytes_read;
        if (callback) {
            if (callback(total_read, expected_size > 0 ? expected_size : total_read, context) != 0) {
                ios_set_error(out_error, "Transfer cancelled.");
                status = -2;
                break;
            }
        }
    }

    free(buf);
    fclose(fp);
    afc_file_close(session.afc, handle);
    ios_close_afc_session(&session);
    return status;
}

int pt_ios_upload_file(
    const char *udid,
    const char *app_bundle_id,
    const char *local_path,
    const char *remote_path,
    uint64_t filesize,
    PTTransferProgressCallback callback,
    void *context,
    char **out_error
) {
    if (out_error) *out_error = NULL;
    FILE *fp = fopen(local_path, "rb");
    if (!fp) {
        ios_set_error(out_error, strerror(errno));
        return -1;
    }

    PTIOSAFCSession session;
    if (ios_open_afc_session(udid, app_bundle_id, &session, out_error) != 0) {
        fclose(fp);
        return -1;
    }

    uint64_t handle = 0;
    afc_error_t err = afc_file_open(session.afc, remote_path, AFC_FOPEN_WRONLY, &handle);
    if (err != AFC_E_SUCCESS) {
        fclose(fp);
        ios_set_error(out_error, afc_strerror(err));
        ios_close_afc_session(&session);
        return -1;
    }

    const uint32_t buf_size = 524288; // 512 KB chunks
    char *buf = (char *)malloc(buf_size);
    if (!buf) {
        afc_file_close(session.afc, handle);
        ios_close_afc_session(&session);
        fclose(fp);
        ios_set_error(out_error, "Out of memory.");
        return -1;
    }

    uint64_t total_written = 0;
    int status = 0;

    while (1) {
        size_t n = fread(buf, 1, buf_size, fp);
        if (n == 0) {
            if (ferror(fp)) {
                ios_set_error(out_error, strerror(errno));
                status = -1;
            }
            break;
        }

        size_t offset = 0;
        while (offset < n) {
            uint32_t written = 0;
            err = afc_file_write(session.afc, handle, buf + offset, (uint32_t)(n - offset), &written);
            if (err != AFC_E_SUCCESS || written == 0) {
                ios_set_error(out_error, err != AFC_E_SUCCESS ? afc_strerror(err) : "Failed to write to iOS device.");
                status = -1;
                break;
            }
            offset += written;
        }
        if (status != 0) break;

        total_written += n;
        if (callback) {
            if (callback(total_written, filesize, context) != 0) {
                ios_set_error(out_error, "Transfer cancelled.");
                status = -2;
                break;
            }
        }
    }

    free(buf);
    fclose(fp);
    afc_file_close(session.afc, handle);

    if (status != 0) {
        afc_remove_path(session.afc, remote_path);
    }

    ios_close_afc_session(&session);
    return status;
}
