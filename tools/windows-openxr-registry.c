/* Only the 64-bit OpenXR ActiveRuntime value is accessible through this helper.
 * Raw registry types and bytes round-trip as JSON/hex, independent of Windows language.
 * Commands: query | write TYPE (hex bytes on stdin) | delete.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const wchar_t registry_key[] = L"SOFTWARE\\Khronos\\OpenXR\\1";
static const wchar_t registry_value[] = L"ActiveRuntime";
enum { max_value_bytes = 1024 * 1024 };

static int fail(LSTATUS status) {
    printf("{\"error\":%lu}\n", (unsigned long)status);
    return 1;
}

static int query(void) {
    HKEY key;
    LSTATUS status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, registry_key, 0,
                                  KEY_QUERY_VALUE | KEY_WOW64_64KEY, &key);
    if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) {
        puts("{\"present\":false}");
        return 0;
    }
    if (status != ERROR_SUCCESS) return fail(status);
    DWORD size = 0, type = 0;
    status = RegQueryValueExW(key, registry_value, NULL, &type, NULL, &size);
    if (status == ERROR_FILE_NOT_FOUND) {
        RegCloseKey(key);
        puts("{\"present\":false}");
        return 0;
    }
    if (status != ERROR_SUCCESS || size > max_value_bytes) {
        RegCloseKey(key);
        return fail(status == ERROR_SUCCESS ? ERROR_FILE_TOO_LARGE : status);
    }
    BYTE *data = malloc(size ? size : 1);
    if (!data) { RegCloseKey(key); return fail(ERROR_NOT_ENOUGH_MEMORY); }
    status = RegQueryValueExW(key, registry_value, NULL, &type, data, &size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) { free(data); return fail(status); }
    printf("{\"present\":true,\"type\":%lu,\"data\":\"", (unsigned long)type);
    for (DWORD i = 0; i < size; ++i) printf("%02x", (unsigned int)data[i]);
    puts("\"}");
    free(data);
    return 0;
}

static int nibble(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int write_value(const char *type_text) {
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(type_text, &end, 10);
    if (!type_text[0] || type_text[0] == '-' || type_text[0] == '+' ||
        errno || !end || *end || parsed > UINT_MAX) return fail(ERROR_INVALID_PARAMETER);
    BYTE *data = malloc(max_value_bytes);
    if (!data) return fail(ERROR_NOT_ENOUGH_MEMORY);
    DWORD size = 0;
    int hi = -1, c;
    while ((c = getchar()) != EOF) {
        if (isspace((unsigned char)c)) continue;
        int value = nibble(c);
        if (value < 0 || size >= max_value_bytes) { free(data); return fail(ERROR_INVALID_DATA); }
        if (hi < 0) hi = value;
        else { data[size++] = (BYTE)((hi << 4) | value); hi = -1; }
    }
    if (hi >= 0 || ferror(stdin)) { free(data); return fail(ERROR_INVALID_DATA); }
    HKEY key;
    LSTATUS status = RegCreateKeyExW(HKEY_LOCAL_MACHINE, registry_key, 0, NULL,
                                    REG_OPTION_NON_VOLATILE, KEY_SET_VALUE | KEY_WOW64_64KEY,
                                    NULL, &key, NULL);
    if (status == ERROR_SUCCESS) {
        status = RegSetValueExW(key, registry_value, 0, (DWORD)parsed, data, size);
        RegCloseKey(key);
    }
    free(data);
    if (status != ERROR_SUCCESS) return fail(status);
    return query();
}

static int delete_value(void) {
    HKEY key;
    LSTATUS status = RegOpenKeyExW(HKEY_LOCAL_MACHINE, registry_key, 0,
                                  KEY_SET_VALUE | KEY_WOW64_64KEY, &key);
    if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) return query();
    if (status != ERROR_SUCCESS) return fail(status);
    status = RegDeleteValueW(key, registry_value);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) return fail(status);
    return query();
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "query")) return query();
    if (argc == 3 && !strcmp(argv[1], "write")) return write_value(argv[2]);
    if (argc == 2 && !strcmp(argv[1], "delete")) return delete_value();
    return fail(ERROR_INVALID_PARAMETER);
}
