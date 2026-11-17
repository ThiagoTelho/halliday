//! Android application packages, as far as running a Quest app needs them (ROADMAP W15.3): the
//! manifest inside an APK, which is Android's binary XML.
//!
//! [`Manifest::parse`] reads `AndroidManifest.xml` as it lies in the package and keeps what
//! Halliday shows and decides by: the package's name and version, its activities, and the
//! native library a `NativeActivity` names. [`Manifest::to_xml`] writes the whole document as
//! text, which is what Klepton's own reader wants beside the unpacked package.
//!
//! The format, from Android's `ResourceTypes.h`: a file is chunks, each starting with a type,
//! a header size and a size; a string pool (UTF-8 or UTF-16), a table of the resource ids of the
//! attribute names, then the tree as start and end records. Attributes whose names the build
//! stripped are named from that table (the handful that matter here).

/// One element of the document.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Element {
    pub name: String,
    /// Attributes: name (with `android:` when it is Android's), value as text.
    pub attributes: Vec<(String, String)>,
    pub children: Vec<Element>,
}

impl Element {
    pub fn attribute(&self, name: &str) -> Option<&str> {
        self.attributes
            .iter()
            .find(|(n, _)| n == name)
            .map(|(_, v)| v.as_str())
    }

    fn write(&self, out: &mut String, depth: usize, root: bool) {
        let pad = "  ".repeat(depth);
        out.push_str(&format!("{pad}<{}", self.name));
        if root {
            out.push_str(" xmlns:android=\"http://schemas.android.com/apk/res/android\"");
        }
        for (name, value) in &self.attributes {
            let value = value
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;")
                .replace('"', "&quot;");
            out.push_str(&format!(" {name}=\"{value}\""));
        }
        if self.children.is_empty() {
            out.push_str(" />\n");
        } else {
            out.push_str(">\n");
            for child in &self.children {
                child.write(out, depth + 1, false);
            }
            out.push_str(&format!("{pad}</{}>\n", self.name));
        }
    }
}

/// An activity the package declares.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Activity {
    /// The class, as written (`com.example.PlayerActivity`).
    pub name: String,
    /// Whether it is what a launcher starts (`MAIN` + `LAUNCHER`).
    pub launcher: bool,
    /// `android.app.lib_name`: the native library a `NativeActivity` runs, without `lib` and
    /// `.so`.
    pub native_library: Option<String>,
    /// Whether it says it is a VR activity (`com.oculus.intent.category.VR`, or OpenXR's
    /// immersive category).
    pub vr: bool,
}

/// What a package says of itself.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Manifest {
    pub package: String,
    pub version_name: String,
    pub version_code: String,
    pub min_sdk: String,
    pub target_sdk: String,
    pub activities: Vec<Activity>,
    pub permissions: Vec<String>,
    /// The whole document.
    pub root: Element,
}

/// Why a manifest couldn't be read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ManifestError {
    /// Not Android's binary XML.
    NotBinaryXml,
    /// A chunk runs past the file, or a string index past the pool.
    Truncated,
    /// No `<manifest>` element.
    NoManifest,
}

const XML: u16 = 0x0003;
const STRING_POOL: u16 = 0x0001;
const RESOURCE_MAP: u16 = 0x0180;
const START_ELEMENT: u16 = 0x0102;
const END_ELEMENT: u16 = 0x0103;
const UTF8: u32 = 1 << 8;

/// Android's attribute names by resource id, for manifests whose names were stripped.
const ANDROID_ATTRIBUTES: &[(u32, &str)] = &[
    (0x0101_0001, "label"),
    (0x0101_0002, "icon"),
    (0x0101_0003, "name"),
    (0x0101_0010, "exported"),
    (0x0101_0024, "value"),
    (0x0101_020c, "minSdkVersion"),
    (0x0101_021b, "versionCode"),
    (0x0101_021c, "versionName"),
    (0x0101_0270, "targetSdkVersion"),
    (0x0101_000c, "hasCode"),
    (0x0101_001d, "launchMode"),
    (0x0101_001e, "screenOrientation"),
    (0x0101_001f, "configChanges"),
    (0x0101_0000, "theme"),
    (0x0101_0012, "taskAffinity"),
    (0x0101_0017, "excludeFromRecents"),
    (0x0101_04f6, "resizeableActivity"),
    (0x0101_0281, "required"),
];

struct Reader<'a>(&'a [u8]);

impl Reader<'_> {
    fn u16(&self, at: usize) -> Result<u16, ManifestError> {
        let b = self.0.get(at..at + 2).ok_or(ManifestError::Truncated)?;
        Ok(u16::from_le_bytes([b[0], b[1]]))
    }
    fn u32(&self, at: usize) -> Result<u32, ManifestError> {
        let b = self.0.get(at..at + 4).ok_or(ManifestError::Truncated)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }
}

/// The string pool at `at`: every string, decoded.
fn strings(r: &Reader, at: usize) -> Result<Vec<String>, ManifestError> {
    let count = r.u32(at + 8)? as usize;
    let flags = r.u32(at + 16)?;
    let start = at + r.u32(at + 20)? as usize;
    let mut out = Vec::with_capacity(count.min(65_536));
    for i in 0..count {
        let mut p = start + r.u32(at + 28 + i * 4)? as usize;
        if flags & UTF8 != 0 {
            // Two lengths, each one or two bytes: the characters, then the bytes.
            for _ in 0..2 {
                let first = *r.0.get(p).ok_or(ManifestError::Truncated)?;
                p += if first & 0x80 != 0 { 2 } else { 1 };
            }
            let first = *r.0.get(p - 1).ok_or(ManifestError::Truncated)?;
            let before = *r.0.get(p - 2).ok_or(ManifestError::Truncated)?;
            let bytes = if before & 0x80 != 0 {
                (usize::from(before & 0x7f) << 8) | usize::from(first)
            } else {
                usize::from(first)
            };
            let text = r.0.get(p..p + bytes).ok_or(ManifestError::Truncated)?;
            out.push(String::from_utf8_lossy(text).into_owned());
        } else {
            let mut units = usize::from(r.u16(p)?);
            p += 2;
            if units & 0x8000 != 0 {
                units = ((units & 0x7fff) << 16) | usize::from(r.u16(p)?);
                p += 2;
            }
            let mut text = Vec::with_capacity(units);
            for k in 0..units {
                text.push(r.u16(p + k * 2)?);
            }
            out.push(String::from_utf16_lossy(&text));
        }
    }
    Ok(out)
}

impl Manifest {
    /// Reads `AndroidManifest.xml` as it lies inside an APK.
    pub fn parse(bytes: &[u8]) -> Result<Manifest, ManifestError> {
        let r = Reader(bytes);
        if bytes.len() < 8 || r.u16(0)? != XML {
            return Err(ManifestError::NotBinaryXml);
        }
        let mut pool: Vec<String> = Vec::new();
        let mut ids: Vec<u32> = Vec::new();
        let mut stack: Vec<Element> = vec![Element::default()];
        let mut at = usize::from(r.u16(2)?);
        while at + 8 <= bytes.len() {
            let (kind, header, size) = (r.u16(at)?, usize::from(r.u16(at + 2)?), r.u32(at + 4)?);
            let size = size as usize;
            if size < 8 || at + size > bytes.len() {
                return Err(ManifestError::Truncated);
            }
            let text = |index: u32| -> Result<Option<String>, ManifestError> {
                if index == u32::MAX {
                    return Ok(None);
                }
                pool.get(index as usize)
                    .cloned()
                    .map(Some)
                    .ok_or(ManifestError::Truncated)
            };
            match kind {
                STRING_POOL => pool = strings(&r, at)?,
                RESOURCE_MAP => {
                    ids = (0..(size - header) / 4)
                        .map(|i| r.u32(at + header + i * 4))
                        .collect::<Result<_, _>>()?;
                }
                START_ELEMENT => {
                    let body = at + header;
                    let name = text(r.u32(body + 4)?)?.unwrap_or_default();
                    let (first, each, count) = (
                        usize::from(r.u16(body + 8)?),
                        usize::from(r.u16(body + 10)?).max(20),
                        usize::from(r.u16(body + 12)?),
                    );
                    let mut attributes = Vec::with_capacity(count);
                    for i in 0..count {
                        let a = body + first + i * each;
                        let (ns, name_index, raw) = (r.u32(a)?, r.u32(a + 4)?, r.u32(a + 8)?);
                        let (kind, data) = (r.0.get(a + 15).copied().unwrap_or(0), r.u32(a + 16)?);
                        let mut name = text(name_index)?.unwrap_or_default();
                        if name.is_empty()
                            && let Some(id) = ids.get(name_index as usize)
                        {
                            name = ANDROID_ATTRIBUTES
                                .iter()
                                .find(|(known, _)| known == id)
                                .map_or_else(|| format!("attr_{id:08x}"), |(_, n)| (*n).to_owned());
                        }
                        // Android's own attributes carry its namespace (or, stripped, an id).
                        if ns != u32::MAX
                            || ids.get(name_index as usize).is_some_and(|id| id >> 24 == 1)
                        {
                            name = format!("android:{name}");
                        }
                        let value = match (text(raw)?, kind) {
                            (Some(raw), _) => raw,
                            (None, 0x03) => text(data)?.unwrap_or_default(),
                            (None, 0x12) => (data != 0).to_string(),
                            (None, 0x10) => (data as i32).to_string(),
                            (None, 0x11) => format!("0x{data:x}"),
                            (None, 0x01 | 0x02) => format!("@0x{data:08x}"),
                            (None, _) => data.to_string(),
                        };
                        attributes.push((name, value));
                    }
                    stack.push(Element {
                        name,
                        attributes,
                        children: Vec::new(),
                    });
                }
                END_ELEMENT => {
                    if stack.len() > 1
                        && let Some(done) = stack.pop()
                        && let Some(parent) = stack.last_mut()
                    {
                        parent.children.push(done);
                    }
                }
                _ => {}
            }
            at += size;
        }
        // Whatever was left open closes at the end of the file.
        while stack.len() > 1 {
            if let (Some(done), Some(parent)) = (stack.pop(), stack.last_mut()) {
                parent.children.push(done);
            }
        }
        let root = stack
            .pop()
            .and_then(|top| top.children.into_iter().find(|e| e.name == "manifest"))
            .ok_or(ManifestError::NoManifest)?;
        let get = |e: &Element, name: &str| e.attribute(name).unwrap_or_default().to_owned();
        let sdk = root.children.iter().find(|e| e.name == "uses-sdk");
        let mut activities = Vec::new();
        for application in root.children.iter().filter(|e| e.name == "application") {
            for a in application.children.iter().filter(|e| e.name == "activity") {
                let categories: Vec<&str> = a
                    .children
                    .iter()
                    .filter(|e| e.name == "intent-filter")
                    .flat_map(|f| f.children.iter())
                    .filter_map(|e| e.attribute("android:name"))
                    .collect();
                activities.push(Activity {
                    name: get(a, "android:name"),
                    launcher: categories.contains(&"android.intent.action.MAIN")
                        && categories.contains(&"android.intent.category.LAUNCHER"),
                    native_library: a
                        .children
                        .iter()
                        .find(|e| {
                            e.name == "meta-data"
                                && e.attribute("android:name") == Some("android.app.lib_name")
                        })
                        .and_then(|e| e.attribute("android:value"))
                        .map(str::to_owned),
                    vr: categories.iter().any(|c| {
                        *c == "com.oculus.intent.category.VR"
                            || *c == "org.khronos.openxr.intent.category.IMMERSIVE_HMD"
                    }),
                });
            }
        }
        Ok(Manifest {
            package: get(&root, "package"),
            version_name: get(&root, "android:versionName"),
            version_code: get(&root, "android:versionCode"),
            min_sdk: sdk
                .map(|e| get(e, "android:minSdkVersion"))
                .unwrap_or_default(),
            target_sdk: sdk
                .map(|e| get(e, "android:targetSdkVersion"))
                .unwrap_or_default(),
            activities,
            permissions: root
                .children
                .iter()
                .filter(|e| e.name == "uses-permission")
                .filter_map(|e| e.attribute("android:name"))
                .map(str::to_owned)
                .collect(),
            root,
        })
    }

    /// The document as text XML.
    pub fn to_xml(&self) -> String {
        let mut out = String::from("<?xml version='1.0' encoding='utf-8'?>\n");
        self.root.write(&mut out, 0, true);
        out
    }

    /// The library a `NativeActivity` of this package runs, if it has one: the VR player of an
    /// app whose other activity is its (web or Java) interface.
    pub fn native_library(&self) -> Option<&str> {
        self.activities
            .iter()
            .find_map(|a| a.native_library.as_deref())
    }
}

/// How a package's game is built, from the libraries it carries (`lib/arm64-v8a/…`): what
/// decides the way Klepton starts it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    Unity,
    Unreal,
    /// A `NativeActivity` of the app's own.
    Native,
    /// ARM64 libraries, but no way in that is known.
    Unknown,
    /// No ARM64 libraries: not something that runs here.
    NotArm64,
}

impl Engine {
    /// From the names of the files in `lib/arm64-v8a` and the manifest.
    pub fn detect<'a>(libraries: impl IntoIterator<Item = &'a str>, manifest: &Manifest) -> Engine {
        let names: Vec<&str> = libraries.into_iter().collect();
        let has = |lib: &str| names.contains(&lib);
        if names.is_empty() {
            Engine::NotArm64
        } else if has("libunity.so") && has("libmain.so") {
            Engine::Unity
        } else if has("libUnreal.so") || has("libUE4.so") {
            Engine::Unreal
        } else if manifest
            .native_library()
            .is_some_and(|lib| has(&format!("lib{lib}.so")))
        {
            Engine::Native
        } else {
            Engine::Unknown
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Engine::Unity => "Unity",
            Engine::Unreal => "Unreal",
            Engine::Native => "native",
            Engine::Unknown => "unknown",
            Engine::NotArm64 => "not ARM64",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a binary manifest the way `aapt2` lays one out: a UTF-8 string pool, a resource
    /// map, then elements. `elements`: (depth change before, name, attributes as (namespace?,
    /// name index or resource id, value)).
    struct Builder {
        strings: Vec<String>,
        body: Vec<u8>,
    }

    impl Builder {
        fn string(&mut self, s: &str) -> u32 {
            if let Some(i) = self.strings.iter().position(|x| x == s) {
                return i as u32;
            }
            self.strings.push(s.to_owned());
            self.strings.len() as u32 - 1
        }

        fn start(&mut self, name: &str, attributes: &[(bool, &str, Value)]) {
            let name = self.string(name);
            let mut chunk = Vec::new();
            chunk.extend_from_slice(&[0; 8]); // line, comment
            chunk.extend_from_slice(&u32::MAX.to_le_bytes()); // namespace
            chunk.extend_from_slice(&name.to_le_bytes());
            chunk.extend_from_slice(&20u16.to_le_bytes());
            chunk.extend_from_slice(&20u16.to_le_bytes());
            chunk.extend_from_slice(&(attributes.len() as u16).to_le_bytes());
            chunk.extend_from_slice(&[0; 6]);
            for (android, attribute, value) in attributes {
                let ns = if *android {
                    self.string("http://schemas.android.com/apk/res/android")
                } else {
                    u32::MAX
                };
                let attribute = self.string(attribute);
                let (raw, kind, data) = match value {
                    Value::Text(t) => {
                        let i = self.string(t);
                        (i, 0x03u8, i)
                    }
                    Value::Int(i) => (u32::MAX, 0x10, *i as u32),
                    Value::Bool(b) => (u32::MAX, 0x12, if *b { u32::MAX } else { 0 }),
                };
                chunk.extend_from_slice(&ns.to_le_bytes());
                chunk.extend_from_slice(&attribute.to_le_bytes());
                chunk.extend_from_slice(&raw.to_le_bytes());
                chunk.extend_from_slice(&8u16.to_le_bytes());
                chunk.push(0);
                chunk.push(kind);
                chunk.extend_from_slice(&data.to_le_bytes());
            }
            self.chunk(START_ELEMENT, &chunk);
        }

        fn end(&mut self) {
            self.chunk(END_ELEMENT, &[0; 16]);
        }

        fn chunk(&mut self, kind: u16, rest: &[u8]) {
            self.body.extend_from_slice(&kind.to_le_bytes());
            self.body.extend_from_slice(&16u16.to_le_bytes());
            self.body
                .extend_from_slice(&(rest.len() as u32 + 8).to_le_bytes());
            self.body.extend_from_slice(rest);
        }

        fn finish(self) -> Vec<u8> {
            // The pool: header (28 bytes), offsets, then the strings (two length bytes, the
            // text, a zero).
            let mut data = Vec::new();
            let mut offsets = Vec::new();
            for s in &self.strings {
                offsets.extend_from_slice(&(data.len() as u32).to_le_bytes());
                data.push(s.chars().count() as u8);
                data.push(s.len() as u8);
                data.extend_from_slice(s.as_bytes());
                data.push(0);
            }
            while data.len() % 4 != 0 {
                data.push(0);
            }
            let start = 28 + offsets.len() as u32;
            let mut pool = Vec::new();
            pool.extend_from_slice(&STRING_POOL.to_le_bytes());
            pool.extend_from_slice(&28u16.to_le_bytes());
            pool.extend_from_slice(&(start + data.len() as u32).to_le_bytes());
            pool.extend_from_slice(&(self.strings.len() as u32).to_le_bytes());
            pool.extend_from_slice(&0u32.to_le_bytes());
            pool.extend_from_slice(&UTF8.to_le_bytes());
            pool.extend_from_slice(&start.to_le_bytes());
            pool.extend_from_slice(&0u32.to_le_bytes());
            pool.extend_from_slice(&offsets);
            pool.extend_from_slice(&data);
            let mut file = Vec::new();
            file.extend_from_slice(&XML.to_le_bytes());
            file.extend_from_slice(&8u16.to_le_bytes());
            file.extend_from_slice(&((8 + pool.len() + self.body.len()) as u32).to_le_bytes());
            file.extend_from_slice(&pool);
            file.extend_from_slice(&self.body);
            file
        }
    }

    enum Value<'a> {
        Text(&'a str),
        Int(i32),
        Bool(bool),
    }

    fn sample() -> Vec<u8> {
        let mut b = Builder {
            strings: Vec::new(),
            body: Vec::new(),
        };
        b.start(
            "manifest",
            &[
                (false, "package", Value::Text("com.example.vr")),
                (true, "versionName", Value::Text("1.9 \"beta\"")),
                (true, "versionCode", Value::Int(396)),
            ],
        );
        b.start("uses-sdk", &[(true, "minSdkVersion", Value::Int(32))]);
        b.end();
        b.start(
            "uses-permission",
            &[(true, "name", Value::Text("android.permission.INTERNET"))],
        );
        b.end();
        b.start("application", &[]);
        b.start(
            "activity",
            &[(true, "name", Value::Text("com.example.MainActivity"))],
        );
        b.start("intent-filter", &[]);
        b.start(
            "action",
            &[(true, "name", Value::Text("android.intent.action.MAIN"))],
        );
        b.end();
        b.start(
            "category",
            &[(
                true,
                "name",
                Value::Text("android.intent.category.LAUNCHER"),
            )],
        );
        b.end();
        b.end();
        b.end();
        b.start(
            "activity",
            &[
                (true, "name", Value::Text("com.example.PlayerActivity")),
                (true, "exported", Value::Bool(true)),
            ],
        );
        b.start(
            "meta-data",
            &[
                (true, "name", Value::Text("android.app.lib_name")),
                (true, "value", Value::Text("player")),
            ],
        );
        b.end();
        b.end();
        b.end();
        b.end();
        b.finish()
    }

    #[test]
    fn a_binary_manifest_is_read() {
        let m = Manifest::parse(&sample()).unwrap();
        assert_eq!(m.package, "com.example.vr");
        assert_eq!(m.version_name, "1.9 \"beta\"");
        assert_eq!((m.version_code.as_str(), m.min_sdk.as_str()), ("396", "32"));
        assert_eq!(m.permissions, ["android.permission.INTERNET"]);
        assert_eq!(m.activities.len(), 2);
        assert!(m.activities[0].launcher && m.activities[0].native_library.is_none());
        assert_eq!(m.activities[1].name, "com.example.PlayerActivity");
        assert_eq!(m.native_library(), Some("player"));
    }

    #[test]
    fn the_document_is_written_as_text() {
        let xml = Manifest::parse(&sample()).unwrap().to_xml();
        assert!(xml.contains("<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"com.example.vr\""));
        assert!(xml.contains("android:versionName=\"1.9 &quot;beta&quot;\""));
        assert!(xml.contains(
            "<activity android:name=\"com.example.PlayerActivity\" android:exported=\"true\">"
        ));
        assert!(xml.contains(
            "<meta-data android:name=\"android.app.lib_name\" android:value=\"player\" />"
        ));
        assert!(xml.trim_end().ends_with("</manifest>"));
    }

    #[test]
    fn what_is_not_a_manifest_is_refused() {
        assert_eq!(
            Manifest::parse(b"<?xml version=\"1.0\"?>"),
            Err(ManifestError::NotBinaryXml)
        );
        let mut cut = sample();
        cut.truncate(cut.len() - 30);
        assert_eq!(Manifest::parse(&cut), Err(ManifestError::Truncated));
    }

    #[test]
    fn the_engine_is_told_from_the_libraries() {
        let m = Manifest::parse(&sample()).unwrap();
        assert_eq!(
            Engine::detect(["libunity.so", "libmain.so", "libil2cpp.so"], &m),
            Engine::Unity
        );
        assert_eq!(Engine::detect(["libUE4.so"], &m), Engine::Unreal);
        assert_eq!(
            Engine::detect(["libplayer.so", "libengine.so"], &m),
            Engine::Native
        );
        assert_eq!(Engine::detect(["libother.so"], &m), Engine::Unknown);
        assert_eq!(Engine::detect([], &m), Engine::NotArm64);
    }
}
