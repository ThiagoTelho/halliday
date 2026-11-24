#include "router_config.hpp"
#include <iostream>
#include <functional>

using namespace halliday::router;
unsigned checks = 0;
void check(bool test, const char* what) { ++checks; if (!test) throw std::runtime_error(what); }
void rejects(const std::function<void()>& action, const char* what) {
    bool failed = false; try { action(); } catch (...) { failed = true; }
    check(failed, what);
}
int main() {
    try {
        auto config = parseConfig(R"({"version":1,"halliday_manifest":"Z:\\Apps\\Halliday\\runtime.json","external_manifest":"C:\\External\\runtime.json","policy_file":"Z:\\policy.json"})");
        check(config.externalManifest == "C:\\External\\runtime.json", "config exact paths");
        auto hallidayOnly = parseConfig(R"({"version":1,"halliday_manifest":"Z:\\h.json","policy_file":"Z:\\p.json"})");
        check(hallidayOnly.externalManifest.empty() && hallidayOnly.externalOpenVRLibrary.empty(), "external runtime was required");
        check(chooseHalliday(Policy{0, false, false, true}, 100000, false), "Halliday-only route requires external runtime or host policy");
        auto legacy = parseConfig(R"({"version":1,"halliday_manifest":"Z:\\h.json","molten_manifest":"C:\\original.json","molten_openvr_library":"C:\\original.dll","policy_file":"Z:\\p.json"})");
        check(legacy.externalManifest == "C:\\original.json" && legacy.externalOpenVRLibrary == "C:\\original.dll", "legacy route keys lost");
        rejects([] { parseConfig(R"({"version":1,"halliday_manifest":"Z:\\h.json","external_manifest":"C:\\a.json","molten_manifest":"C:\\b.json","policy_file":"Z:\\p.json"})"); }, "conflicting old/new keys accepted");
        check(isAbsolutePath(R"(\\server\share\runtime.json)"), "UNC absolute");
        for (auto path : {"", "file.json", "C:relative", "\\rooted", "/tmp/file", "1:\\path"})
            check(!isAbsolutePath(path), "relative path accepted");
        for (auto bad : {R"({"version":1,"version":1})", R"({"version":1.0})", "{}", "[]", "true", "", "{broken",
                         R"({"version":18446744073709551616})", R"({"version":-1})"})
            rejects([&] { parseConfig(bad); }, "bad config accepted");
        auto withVr = Json{{"version",1},{"halliday_manifest","Z:\\h.json"},{"external_manifest","C:\\m.json"},{"policy_file","Z:\\p.json"},
                           {"halliday_openvr_library","Z:\\h.dll"},{"external_openvr_library","C:\\m.dll"}};
        check(parseConfig(withVr.dump()).hallidayOpenVRLibrary == "Z:\\h.dll", "optional OpenVR path lost");
        check(!parseConfig(withVr.dump()).externalSafeErrorStrings, "external ClientCore unexpectedly wrapped");
        withVr["external_safe_error_strings"] = true;
        check(parseConfig(withVr.dump()).externalSafeErrorStrings, "optional error-string compatibility lost");
        withVr["external_safe_error_strings"] = 1;
        rejects([&]{parseConfig(withVr.dump());},"numeric compatibility bool accepted");
        withVr.erase("external_safe_error_strings");
        withVr["external_openvr_library"]="relative.dll";
        rejects([&]{parseConfig(withVr.dump());},"relative optional OpenVR path accepted");
        auto unicode = parseJson(R"({"a":"\u041a\u0432\u0435\u0441\u0442 \ud83d\ude80"})");
        check(unicode["a"] == "Квест 🚀", "Unicode/surrogate paths lost");
        rejects([] { parseJson(R"({"nested":{"x":1,"x":2}})"); }, "nested duplicate accepted");
        rejects([] { parseJson(R"({"a":"\ud800"})"); }, "invalid surrogate accepted");
        rejects([] { parseJson("{} trailing"); }, "trailing data accepted");
        std::string nested(40, '['); nested += '0'; nested += std::string(40, ']');
        rejects([&] { parseJson(nested); }, "unbounded recursion accepted");
        rejects([] { parsePolicy(std::string(kPolicyBytes + 1, ' ')); }, "large policy accepted");
        rejects([] { parseConfig(std::string(kConfigBytes + 1, ' ')); }, "large config accepted");
        constexpr uint64_t now = 100000;
        for (bool ready : {false, true}) for (bool worn : {false, true}) for (bool external : {false, true}) {
            Policy p{now, ready, worn, external};
            check(chooseHalliday(p, now) == (ready && (worn || !external)), "truth table mismatch");
            p.updatedUnixMs = now - 3000;
            check(chooseHalliday(p, now) == (ready && (worn || !external)), "TTL inclusive edge");
            p.updatedUnixMs = now - 3001; check(!chooseHalliday(p, now), "stale policy accepted");
            p.updatedUnixMs = now + 500;
            check(chooseHalliday(p, now) == (ready && (worn || !external)), "future inclusive edge");
            p.updatedUnixMs = now + 501; check(!chooseHalliday(p, now), "future policy accepted");
        }
        Policy p{std::numeric_limits<uint64_t>::max(), true, true, false};
        check(!chooseHalliday(p, 1), "future overflow accepted");
        p.updatedUnixMs = 1; check(!chooseHalliday(p, std::numeric_limits<uint64_t>::max()), "age overflow accepted");
        auto good = Json{{"version",1},{"updated_unix_ms",now},{"halliday_ready",true},{"psvr2_worn",true},{"external_active",true}};
        check(chooseHalliday(parsePolicy(good.dump()), now), "valid policy rejected");
        auto oldPolicy = good; oldPolicy.erase("external_active"); oldPolicy["molten_running"] = true;
        check(chooseHalliday(parsePolicy(oldPolicy.dump()), now), "legacy activity key lost");
        oldPolicy["external_active"] = false;
        rejects([&]{parsePolicy(oldPolicy.dump());},"conflicting activity keys accepted");
        for (auto key : {"halliday_ready", "psvr2_worn", "external_active"}) {
            auto bad=good; bad[key]=1; rejects([&] { parsePolicy(bad.dump()); }, "numeric bool accepted");
            bad.erase(key); rejects([&] { parsePolicy(bad.dump()); }, "missing bool accepted");
        }
        for (auto value : {Json(-1), Json(1.5), Json("100000"), Json(nullptr)}) {
            auto bad=good; bad["updated_unix_ms"]=value;
            rejects([&] { parsePolicy(bad.dump()); }, "bad timestamp accepted");
        }
        rejects([] { parsePolicy(R"({"version":1,"updated_unix_ms":1,"halliday_ready":true,"psvr2_worn":true,"external_active":false,"psvr2_worn":false})"); }, "duplicate policy accepted");
        auto manifest=parseManifest(R"({"file_format_version":"1.0.0","runtime":{"library_path":"./runtime.dll","functions":{"xrNegotiateLoaderRuntimeInterface":"testNegotiate"}}})");
        check(manifest.library == "./runtime.dll" && manifest.negotiate == "testNegotiate", "manifest remap ignored");
        check(parseManifest(R"({"file_format_version":"1.0.0","runtime":{"library_path":"runtime.dll"}})").negotiate == "xrNegotiateLoaderRuntimeInterface", "default export wrong");
        for (auto bad : {R"({"file_format_version":"2.0.0","runtime":{"library_path":"x"}})",
             R"({"file_format_version":"1.0.0","runtime":{"library_path":"x","library_path":"y"}})",
             R"({"file_format_version":"1.0.0","runtime":{"library_path":"x\u0000y"}})",
             R"({"file_format_version":"1.0.0","runtime":{"library_path":"x","functions":{"xrNegotiateLoaderRuntimeInterface":"bad export"}}})"})
            rejects([&] { parseManifest(bad); }, "bad manifest accepted");
        std::cout << "PASS: " << checks << " strict JSON/path/policy/time/manifest checks\n";
    } catch (const std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
}
