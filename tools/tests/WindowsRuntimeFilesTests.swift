import Foundation

@main struct WindowsRuntimeFilesTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/halliday-windows-runtime-files-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let prefix = root.appendingPathComponent("Bottle"), drive = prefix.appendingPathComponent("drive_c")
        let mapped = root.appendingPathComponent("External 測試")
        for p in [prefix.appendingPathComponent("dosdevices"), drive, mapped] {
            try fm.createDirectory(at: p, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(at: prefix.appendingPathComponent("dosdevices/z:"), withDestinationURL: URL(fileURLWithPath: "/"))
        try fm.createSymbolicLink(at: prefix.appendingPathComponent("dosdevices/d:"), withDestinationURL: mapped)
        func write(_ file: URL, _ data: Data) throws {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        func manifest(_ file: URL, library: String) throws {
            try write(file, JSONSerialization.data(withJSONObject: ["runtime": ["library_path": library]]))
        }
        func pe(machine: UInt16 = 0x8664, magic: UInt16 = 0x20b, flags: UInt16 = 0x2022) -> Data {
            var b = [UInt8](repeating: 0, count: 512)
            func u16(_ p: Int, _ n: UInt16) { b[p] = UInt8(n & 255); b[p + 1] = UInt8(n >> 8) }
            func u32(_ p: Int, _ n: UInt32) { for i in 0..<4 { b[p + i] = UInt8((n >> (8 * i)) & 255) } }
            b[0] = 0x4d; b[1] = 0x5a; u32(0x3c, 0x80)
            b[0x80] = 0x50; b[0x81] = 0x45
            u16(0x84, machine); u16(0x86, 1); u16(0x94, 240); u16(0x96, flags)
            u16(0x98, magic); u32(0x98 + 56, 0x2000); u32(0x98 + 60, 512)
            return Data(b)
        }
        func library(_ path: String) -> URL? { WindowsRuntimeFiles.library(prefix: prefix, manifestPath: path) }
        func same(_ actual: URL?, _ expected: URL) -> Bool {
            actual?.resolvingSymlinksInPath().path == expected.resolvingSymlinksInPath().path
        }
        let dll = drive.appendingPathComponent("OpenXR/Runtime.DLL"), config = drive.appendingPathComponent("OpenXR/Runtime.json")
        try write(dll, pe()); try manifest(config, library: "Runtime.DLL")
        precondition(WindowsRuntimeFiles.isWindowsDLL(dll))
        precondition(same(library("C:\\OpenXR\\Runtime.json"), dll))
        precondition(same(library("c:/openxr/runtime.JSON"), dll), "Windows case-insensitive resolution failed")
        try manifest(config, library: "c:\\openxr\\runtime.dll")
        precondition(same(library("C:/OpenXR/Runtime.json"), dll))
        let externalDLL = mapped.appendingPathComponent("VR 🚀/Module.dll"), externalJSON = mapped.appendingPathComponent("VR 🚀/runtime.json")
        try write(externalDLL, pe()); try manifest(externalJSON, library: "Module.dll")
        precondition(same(library("D:\\VR 🚀\\runtime.json"), externalDLL))
        precondition(same(library("Z:" + externalJSON.path), externalDLL))
        let registeredOpenVR = mapped.appendingPathComponent("OpenVR/bin/win64/vrclient_x64.dll")
        try write(registeredOpenVR, pe())
        precondition(same(WindowsRuntimeFiles.openVRLibrary(prefix: prefix, runtimePath: "D:\\OpenVR"), registeredOpenVR))
        precondition(WindowsRuntimeFiles.openVRLibrary(prefix: prefix, runtimePath: "D:OpenVR") == nil)
        precondition(WindowsRuntimeFiles.openVRLibrary(prefix: prefix, runtimePath: "D:\\VR 🚀") == nil,
                     "A sibling OpenXR DLL became an inferred OpenVR provider")
        let classicOpenVR = mapped.appendingPathComponent("ClassicVR/bin/vrclient_x64.dll")
        try write(classicOpenVR, pe())
        precondition(same(WindowsRuntimeFiles.openVRLibrary(prefix: prefix, runtimePath: "D:\\ClassicVR"), classicOpenVR))
        precondition(WindowsRuntimeFiles.isWithin(registeredOpenVR, directory: mapped))
        precondition(!WindowsRuntimeFiles.isWithin(mapped.appendingPathComponent("Other/file"), directory: mapped.appendingPathComponent("Open")))
        try manifest(config, library: "D:/VR 🚀/Module.dll")
        precondition(same(library("C:/OpenXR/Runtime.json"), externalDLL))

        let relativeDLL = drive.appendingPathComponent("Bin/Runtime.dll")
        try write(relativeDLL, pe()); try manifest(config, library: "..\\Bin\\Runtime.dll")
        precondition(same(library("C:/OpenXR/Runtime.json"), relativeDLL))
        precondition(same(library("C:/../../OpenXR/./Runtime.json"), relativeDLL), "Manifest .. escaped drive root")
        try manifest(config, library: "../../../../Bin/Runtime.dll")
        precondition(same(library("C:/OpenXR/Runtime.json"), relativeDLL), "DLL .. escaped drive root")
        let hostOnly = prefix.appendingPathComponent("outside.dll")
        try write(hostOnly, pe()); try manifest(config, library: "../../outside.dll")
        precondition(library("C:/OpenXR/Runtime.json") == nil, "Windows .. escaped to a host parent")
        try fm.removeItem(at: prefix.appendingPathComponent("dosdevices/c:"))
        try manifest(config, library: "Runtime.DLL")
        precondition(same(library("C:/OpenXR/Runtime.json"), dll), "Conventional drive_c fallback failed")
        let cMap = prefix.appendingPathComponent("dosdevices/c:")
        try fm.createSymbolicLink(at: cMap, withDestinationURL: root.appendingPathComponent("missing-drive"))
        precondition(library("C:/OpenXR/Runtime.json") == nil, "Dangling explicit drive mapping silently used drive_c")
        try fm.removeItem(at: cMap)
        try write(cMap, Data("not a drive".utf8))
        precondition(library("C:/OpenXR/Runtime.json") == nil, "Non-directory drive mapping accepted")
        try fm.removeItem(at: cMap)

        for path in ["", "Runtime.json", "C:OpenXR\\Runtime.json", "Q:\\runtime.json", "\\\\server\\share\\runtime.json",
                     "\\\\?\\C:\\runtime.json", "/private/tmp/runtime.json", "𝖢:/OpenXR/Runtime.json", "C:/OpenXR/Runtime.json\0"] {
            precondition(library(path) == nil, "Unsupported manifest path accepted")
        }
        for path in ["", "missing.dll", "Q:\\missing.dll", "C:Runtime.DLL", "\\\\server\\share\\module.dll", "/native.dylib", "bad\0.dll"] {
            try manifest(config, library: path)
            precondition(library("C:/OpenXR/Runtime.json") == nil, "Unsupported DLL path accepted")
        }
        for data in [Data(), Data("{broken".utf8), Data("{}".utf8), Data("{\"runtime\":{\"library_path\":true}}".utf8),
                     Data("{\"runtime\":{\"library_path\":null}}".utf8), Data(repeating: 32, count: 16 * 1024 + 1)] {
            try write(config, data)
            precondition(library("C:/OpenXR/Runtime.json") == nil)
        }
        let start = "{\"runtime\":{\"library_path\":\"Runtime.DLL\"},\"padding\":\"", end = "\"}"
        let exact = start + String(repeating: "x", count: 16 * 1024 - start.utf8.count - end.utf8.count) + end
        try write(config, Data(exact.utf8))
        precondition(same(library("C:/OpenXR/Runtime.json"), dll), "Exact16KiB manifest rejected")
        try write(config, Data((exact + " ").utf8))
        precondition(library("C:/OpenXR/Runtime.json") == nil)

        let bad = root.appendingPathComponent("bad.dll")
        var malformed = [Data(), Data([0xcf, 0xfa, 0xed, 0xfe]), Data("native.dylib".utf8), pe(machine: 0x14c),
                         pe(machine: 0xaa64), pe(magic: 0x10b), pe(flags: 0x22), Data(pe().prefix(63)), Data(pe().prefix(180))]
        for position in [0, 0x80, 0x82, 0x94, 0x95, 0x98] {
            var data = pe(); data[position] ^= 0xff; malformed.append(data)
        }
        var farPE = pe(); farPE[0x3c] = 0xff; farPE[0x3d] = 0xff; farPE[0x3e] = 0xff; farPE[0x3f] = 0x7f
        malformed.append(farPE)
        for data in malformed {
            try write(bad, data)
            precondition(!WindowsRuntimeFiles.isWindowsDLL(bad), "Malformed, native, EXE or wrong-arch header accepted")
        }
        precondition(!WindowsRuntimeFiles.isWindowsDLL(root))
        precondition(!WindowsRuntimeFiles.isWindowsDLL(root.appendingPathComponent("missing.dll")))
        let fifo = root.appendingPathComponent("pipe.dll")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        precondition(!WindowsRuntimeFiles.isWindowsDLL(fifo), "Pipe accepted or blocked")
        try write(bad, pe(machine: 0x14c)); try manifest(config, library: "Z:" + bad.path)
        precondition(library("C:/OpenXR/Runtime.json") == nil, "Manifest bypassed PE validation")
        try write(bad, pe())
        precondition(same(library("C:/OpenXR/Runtime.json"), bad))
        for argument in CommandLine.arguments.dropFirst() {
            precondition(WindowsRuntimeFiles.isWindowsDLL(URL(fileURLWithPath: argument)), "Installed positive-control DLL rejected")
            print("PASS installed AMD64 PE32+ DLL header: \(URL(fileURLWithPath: argument).lastPathComponent)")
        }
        print("PASS: Windows C/Z/external drives and Unicode/case, relative DLL resolution, drive-root .. clamp,16KiB bound, strict manifests, bounded AMD64 PE32+ DLL header validation, wrongarch/native/EXE/missing/directory/pipe rejection")
    }
}
