// Halliday's process-local OpenXR backend selection. No runtime API interposition.
#pragma once

#include <nlohmann/json.hpp>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

namespace halliday::router {
using Json = nlohmann::json;
constexpr size_t kConfigBytes = 16 * 1024;
constexpr size_t kPolicyBytes = 4 * 1024;
constexpr uint64_t kPolicyLifetimeMs = 3000;
constexpr uint64_t kPolicyFutureMs = 500;

inline Json parseJson(const std::string& bytes) {
    // nlohmann normally keeps the last duplicate key. That is unsafe for a routing
    // decision, so reject duplicates at every nesting level instead.
    std::vector<std::unordered_set<std::string>> keys;
    auto callback = [&](int depth, Json::parse_event_t event, Json& value) {
        if (depth > 32) throw std::runtime_error("JSON nesting exceeds limit");
        if (event == Json::parse_event_t::object_start) keys.emplace_back();
        else if (event == Json::parse_event_t::key) {
            if (keys.empty() || !keys.back().insert(value.get<std::string>()).second)
                throw std::runtime_error("duplicate JSON key");
        } else if (event == Json::parse_event_t::object_end) keys.pop_back();
        return true;
    };
    return Json::parse(bytes, callback, true, false);
}

inline uint64_t unsignedInteger(const Json& object, const char* key) {
    const auto& value = object.at(key);
    if (!value.is_number_unsigned()) throw std::runtime_error(std::string("invalid integer: ") + key);
    return value.get<uint64_t>();
}
inline std::string stringValue(const Json& object, const char* key) {
    const auto& value = object.at(key);
    if (!value.is_string()) throw std::runtime_error(std::string("invalid string: ") + key);
    auto text = value.get<std::string>();
    if (text.empty() || text.find('\0') != std::string::npos)
        throw std::runtime_error(std::string("empty or embedded NUL: ") + key);
    return text;
}
inline bool boolean(const Json& object, const char* key) {
    const auto& value = object.at(key);
    if (!value.is_boolean()) throw std::runtime_error(std::string("invalid boolean: ") + key);
    return value.get<bool>();
}
inline std::string optionalPath(const Json& object, const char* key) {
    return object.contains(key) ? stringValue(object, key) : std::string{};
}
inline bool isAbsolutePath(const std::string& text) {
    const auto slash = [](char c) { return c == '\\' || c == '/'; };
    const bool drive = text.size() >= 3 &&
        ((text[0] >= 'A' && text[0] <= 'Z') || (text[0] >= 'a' && text[0] <= 'z')) &&
        text[1] == ':' && slash(text[2]);
    const bool unc = text.size() >= 5 && text[0] == '\\' && text[1] == '\\' &&
        text[2] != '\\' && text[2] != '.' && text.find('\\', 2) != std::string::npos;
    return drive || unc;
}

struct Config {
    std::string hallidayManifest, externalManifest, policyFile, hallidayOpenVRLibrary, externalOpenVRLibrary;
    bool externalSafeErrorStrings = false;
};
inline Config parseConfig(const std::string& bytes) {
    if (bytes.size() > kConfigBytes) throw std::runtime_error("config exceeds limit");
    auto root = parseJson(bytes);
    if (!root.is_object() || unsignedInteger(root, "version") != 1)
        throw std::runtime_error("unsupported config version");
    Config c{stringValue(root, "halliday_manifest"), optionalPath(root, "external_manifest"), stringValue(root, "policy_file"), {}, {}};
    if (!isAbsolutePath(c.hallidayManifest) || (!c.externalManifest.empty() && !isAbsolutePath(c.externalManifest)) || !isAbsolutePath(c.policyFile))
        throw std::runtime_error("config paths must be absolute Windows paths");
    if (root.contains("halliday_openvr_library")) {
        c.hallidayOpenVRLibrary = stringValue(root, "halliday_openvr_library");
        if (!isAbsolutePath(c.hallidayOpenVRLibrary)) throw std::runtime_error("OpenVR library must be absolute");
    }
    c.externalOpenVRLibrary = optionalPath(root, "external_openvr_library");
    if (!c.externalOpenVRLibrary.empty() && !isAbsolutePath(c.externalOpenVRLibrary)) throw std::runtime_error("OpenVR library must be absolute");
    if (root.contains("external_safe_error_strings")) c.externalSafeErrorStrings = boolean(root, "external_safe_error_strings");
    return c;
}

struct Policy { uint64_t updatedUnixMs; bool ready, worn, externalActive; };
inline Policy parsePolicy(const std::string& bytes) {
    if (bytes.size() > kPolicyBytes) throw std::runtime_error("policy exceeds limit");
    auto root = parseJson(bytes);
    if (!root.is_object() || unsignedInteger(root, "version") != 1)
        throw std::runtime_error("unsupported policy version");
    return {unsignedInteger(root, "updated_unix_ms"), boolean(root, "halliday_ready"),
            boolean(root, "psvr2_worn"), boolean(root, "external_active")};
}
inline bool chooseHalliday(const Policy& p, uint64_t now, bool externalConfigured = true) {
    if (!externalConfigured) return true;
    const bool fresh = p.updatedUnixMs > now ? p.updatedUnixMs - now <= kPolicyFutureMs
                                            : now - p.updatedUnixMs <= kPolicyLifetimeMs;
    return fresh && p.ready && (p.worn || !p.externalActive);
}

struct Manifest { std::string library, negotiate; };
inline Manifest parseManifest(const std::string& bytes) {
    if (bytes.size() > kConfigBytes) throw std::runtime_error("manifest exceeds limit");
    auto root = parseJson(bytes);
    if (stringValue(root, "file_format_version") != "1.0.0")
        throw std::runtime_error("unsupported manifest version");
    const auto& runtime = root.at("runtime");
    Manifest m{stringValue(runtime, "library_path"), "xrNegotiateLoaderRuntimeInterface"};
    if (runtime.contains("functions")) {
        const auto& functions = runtime.at("functions");
        if (!functions.is_object()) throw std::runtime_error("invalid functions map");
        if (functions.contains("xrNegotiateLoaderRuntimeInterface"))
            m.negotiate = stringValue(functions, "xrNegotiateLoaderRuntimeInterface");
    }
    if (m.negotiate.size() > 256 || m.negotiate.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") != std::string::npos)
        throw std::runtime_error("invalid negotiation function name");
    return m;
}
} // namespace halliday::router
