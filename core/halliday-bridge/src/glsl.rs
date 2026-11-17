//! Old GLSL to the GLSL macOS's core OpenGL accepts (used by `halliday-vrclient`, which hands a
//! game's shaders to OpenGL through this when the game was given a core context instead of the
//! compatibility one it asked for: see its `glfix.rs`).
//!
//! macOS's core profile takes GLSL 1.50 and later only. Games written for compatibility contexts
//! (the OpenGL game: GLSL ES 1.00-style shaders with no version, `#version 100`, `110` or `130`)
//! use `attribute`, `varying`, `gl_FragColor` and `texture2D`, and GLSL ES precision words. This
//! rewrites them, word by word, outside comments:
//!
//! - the `#version` line becomes `#version 150` (GLSL ES 3.00 shaders: `#version 330`);
//! - `#extension` lines are dropped (what they enabled is core in GLSL 1.50);
//! - `precision …;` statements are dropped and `lowp` / `mediump` / `highp` removed (desktop GLSL
//!   ignores them, and two stages disagreeing on a uniform's precision fails to link);
//! - vertex shaders: `attribute` → `in`, `varying` → `out`; fragment shaders: `varying` → `in`,
//!   `gl_FragColor` / `gl_FragData` → a declared output;
//! - `texture2D`, `textureCube`, `texture2DProj`, `texture2DLod`, `textureCubeLod` and their `EXT`
//!   forms → `texture`, `textureProj`, `textureLod`, `textureGrad`;
//! - a `;` right after the closing brace of a block opened after `)` (a function's body,
//!   `void main() { … };`, accepted by GLSL ES and refused by Apple's compiler; inside a function
//!   it is an empty statement) is dropped; a struct's, an interface block's or an initializer's
//!   is kept. Likewise after a top-level call of a function-like macro whose body ends with `}`
//!   (a macro that defines a function: `MS_SHARP(vec4, F, G, vec2);`).
//!
//! What has no equivalent in a core context (fixed-function built-ins such as `gl_Vertex` or
//! `ftransform`) is left as is: such a shader still fails, and the runtime logs it.

/// The output is written into `out`; its length, or `None` if it doesn't fit.
pub fn translate(src: &[u8], fragment: bool, out: &mut [u8]) -> Option<usize> {
    let mut w = Writer { out, len: 0 };
    let es3 = find_version(src).is_some_and(|v| v.starts_with(b"300"));
    w.put(if es3 {
        b"#version 330\n"
    } else {
        b"#version 150\n"
    })?;
    if fragment && !es3 {
        if contains_word(src, b"gl_FragData") {
            w.put(b"out vec4 halliday_FragData[4];\n")?;
        } else if contains_word(src, b"gl_FragColor") {
            w.put(b"out vec4 halliday_FragColor;\n")?;
        }
    }
    let mut state = State::default();
    let macros = FunctionMacros::scan(src);
    let body = src.strip_suffix(b"\n").unwrap_or(src);
    for line in body.split(|&c| c == b'\n') {
        let trimmed = trim(line);
        if !state.in_comment && trimmed.starts_with(b"#") {
            let directive = trim(&trimmed[1..]);
            if directive.starts_with(b"version") || directive.starts_with(b"extension") {
                w.put(b"\n")?; // keeps the line numbers of the driver's messages
                continue;
            }
            w.put(line)?;
            w.put(b"\n")?;
            continue;
        }
        if !state.in_comment && trimmed.starts_with(b"precision ") && trimmed.ends_with(b";") {
            w.put(b"\n")?;
            continue;
        }
        rewrite_line(line, fragment, es3, &macros, &mut state, &mut w)?;
        w.put(b"\n")?;
    }
    Some(w.len)
}

struct Writer<'a> {
    out: &'a mut [u8],
    len: usize,
}

impl Writer<'_> {
    fn put(&mut self, bytes: &[u8]) -> Option<()> {
        let end = self.len.checked_add(bytes.len())?;
        self.out.get_mut(self.len..end)?.copy_from_slice(bytes);
        self.len = end;
        Some(())
    }
}

fn trim(s: &[u8]) -> &[u8] {
    let start = s
        .iter()
        .position(|c| !c.is_ascii_whitespace())
        .unwrap_or(s.len());
    let end = s
        .iter()
        .rposition(|c| !c.is_ascii_whitespace())
        .map_or(start, |e| e + 1);
    &s[start..end.max(start)]
}

fn find_version(src: &[u8]) -> Option<&[u8]> {
    src.split(|&c| c == b'\n').find_map(|line| {
        let t = trim(line);
        let rest = t.strip_prefix(b"#")?;
        let rest = trim(rest).strip_prefix(b"version")?;
        Some(trim(rest))
    })
}

fn is_ident(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_'
}

fn contains_word(src: &[u8], word: &[u8]) -> bool {
    let mut i = 0;
    while i + word.len() <= src.len() {
        if &src[i..i + word.len()] == word
            && (i == 0 || !is_ident(src[i - 1]))
            && src.get(i + word.len()).is_none_or(|&c| !is_ident(c))
        {
            return true;
        }
        i += 1;
    }
    false
}

/// Function-like macros whose body ends with `}`: calling one defines a function.
struct FunctionMacros<'a> {
    names: [&'a [u8]; 32],
    count: usize,
}

impl<'a> FunctionMacros<'a> {
    fn scan(src: &'a [u8]) -> Self {
        let mut m = FunctionMacros {
            names: [b""; 32],
            count: 0,
        };
        let mut iter = src.split(|&c| c == b'\n');
        while let Some(line) = iter.next() {
            let t = trim(line);
            let Some(rest) = t
                .strip_prefix(b"#")
                .map(trim)
                .and_then(|r| r.strip_prefix(b"define"))
            else {
                continue;
            };
            let rest = trim(rest);
            let name_len = rest
                .iter()
                .position(|&c| !is_ident(c))
                .unwrap_or(rest.len());
            if name_len == 0 || rest.get(name_len) != Some(&b'(') {
                continue;
            }
            // The body's last line: follow the backslash continuations.
            let mut last = t;
            while last.ends_with(b"\\") {
                match iter.next() {
                    Some(next) => last = trim(next),
                    None => break,
                }
            }
            if trim(last.strip_suffix(b"\\").unwrap_or(last)).ends_with(b"}")
                && m.count < m.names.len()
            {
                m.names[m.count] = &rest[..name_len];
                m.count += 1;
            }
        }
        m
    }

    fn contains(&self, word: &[u8]) -> bool {
        self.names[..self.count].contains(&word)
    }
}

/// What carries from one line to the next.
#[derive(Default)]
struct State {
    in_comment: bool,
    /// Open blocks: whether each was opened right after `)` (bit per depth, innermost lowest).
    after_paren: u64,
    depth: u32,
    /// The last character of code written (not whitespace or comment).
    last: u8,
    /// A block opened after `)` just closed: a `;` right after it is dropped.
    after_function: bool,
    /// Inside the arguments of a top-level call of a function-defining macro: paren depth + 1.
    macro_call: u32,
}

/// One line of code, rewritten word by word (comments and their contents untouched).
fn rewrite_line(
    line: &[u8],
    fragment: bool,
    es3: bool,
    macros: &FunctionMacros,
    st: &mut State,
    w: &mut Writer,
) -> Option<()> {
    let mut i = 0;
    while i < line.len() {
        if st.in_comment {
            if line[i..].starts_with(b"*/") {
                w.put(b"*/")?;
                i += 2;
                st.in_comment = false;
            } else {
                w.put(&line[i..i + 1])?;
                i += 1;
            }
            continue;
        }
        if line[i..].starts_with(b"//") {
            w.put(&line[i..])?;
            break;
        }
        if line[i..].starts_with(b"/*") {
            w.put(b"/*")?;
            i += 2;
            st.in_comment = true;
            continue;
        }
        let c = line[i];
        if !c.is_ascii_whitespace() {
            if st.after_function {
                st.after_function = false;
                if c == b';' {
                    i += 1;
                    continue;
                }
            }
            match c {
                b'{' => {
                    st.after_paren = st.after_paren << 1 | (st.last == b')') as u64;
                    st.depth += 1;
                }
                b'}' => {
                    st.after_function = st.depth > 0 && st.after_paren & 1 == 1;
                    st.after_paren >>= 1;
                    st.depth = st.depth.saturating_sub(1);
                }
                b'(' if st.macro_call > 0 => st.macro_call += 1,
                b')' if st.macro_call > 0 => {
                    st.macro_call -= 1;
                    if st.macro_call == 1 {
                        st.macro_call = 0;
                        st.after_function = true;
                    }
                }
                _ => {}
            }
            st.last = c;
        }
        if is_ident(line[i]) && (i == 0 || !is_ident(line[i - 1])) {
            let end = line[i..]
                .iter()
                .position(|&c| !is_ident(c))
                .map_or(line.len(), |n| i + n);
            let word = &line[i..end];
            let replacement: Option<&[u8]> = match word {
                b"lowp" | b"mediump" | b"highp" => Some(b""),
                _ if es3 => None,
                b"attribute" if !fragment => Some(b"in"),
                b"varying" => Some(if fragment { b"in" } else { b"out" }),
                b"gl_FragColor" if fragment => Some(b"halliday_FragColor"),
                b"gl_FragData" if fragment => Some(b"halliday_FragData"),
                b"texture2D" | b"textureCube" | b"shadow2D" => Some(b"texture"),
                b"texture2DProj" | b"shadow2DProj" => Some(b"textureProj"),
                b"texture2DLod" | b"textureCubeLod" | b"texture2DLodEXT" | b"textureCubeLodEXT" => {
                    Some(b"textureLod")
                }
                b"texture2DGradEXT" | b"textureCubeGradEXT" => Some(b"textureGrad"),
                b"texture2DProjLod" | b"texture2DProjLodEXT" => Some(b"textureProjLod"),
                _ => None,
            };
            if st.depth == 0 && st.macro_call == 0 && macros.contains(word) {
                st.macro_call = 1; // its `(` comes next and makes it 2
            }
            w.put(replacement.unwrap_or(word))?;
            st.last = b'a';
            i = end;
            continue;
        }
        w.put(&line[i..i + 1])?;
        i += 1;
    }
    Some(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(src: &str, fragment: bool) -> std::string::String {
        let mut out = [0u8; 4096];
        let n = translate(src.as_bytes(), fragment, &mut out).unwrap();
        std::string::String::from_utf8(out[..n].to_vec()).unwrap()
    }

    extern crate std;

    #[test]
    fn legacy_vertex_shader() {
        let out = run(
            "uniform mat4 uClipFromStartMatrix;\nattribute vec3 aVertex;\nvarying vec2 vTexCoords;\nvoid main(void) {\n  gl_Position = uClipFromStartMatrix * vec4(aVertex, 1.0);\n}\n",
            false,
        );
        assert!(out.starts_with("#version 150\n"), "{out}");
        assert!(out.contains("in vec3 aVertex;"), "{out}");
        assert!(out.contains("out vec2 vTexCoords;"), "{out}");
        assert!(out.contains("gl_Position = uClipFromStartMatrix"), "{out}");
    }

    #[test]
    fn legacy_fragment_shader_with_precision_and_version_130() {
        let out = run(
            "#version 130\n#ifdef GL_ES\nprecision mediump float;\n#else\n#define GLSL_STANDARD_DERIVATIVES\n#endif\n#extension GL_OES_standard_derivatives : enable\nuniform highp vec4 uRingColor;\nuniform sampler2D uSampler;\nvarying vec2 vTex;\nvoid main(void) {\n  // texture2D in a comment stays\n  gl_FragColor = texture2D(uSampler, vTex) * uRingColor; /* varying */\n}\n",
            true,
        );
        assert!(
            out.starts_with("#version 150\nout vec4 halliday_FragColor;\n"),
            "{out}"
        );
        assert!(!out.contains("#version 130"), "{out}");
        assert!(!out.contains("#extension"), "{out}");
        assert!(!out.contains("precision mediump"), "{out}");
        assert!(out.contains("uniform  vec4 uRingColor;"), "{out}");
        assert!(out.contains("in vec2 vTex;"), "{out}");
        assert!(
            out.contains(
                "halliday_FragColor = texture(uSampler, vTex) * uRingColor; /* varying */"
            ),
            "{out}"
        );
        assert!(out.contains("// texture2D in a comment stays"), "{out}");
        assert!(out.contains("#define GLSL_STANDARD_DERIVATIVES"), "{out}");
        // Same number of lines after the header, so the driver's line numbers still match.
        assert_eq!(out.lines().count(), 2 + 14);
    }

    #[test]
    fn gles3_shaders_keep_their_words() {
        let out = run(
            "#version 300 es\nprecision highp float;\nin vec2 v;\nout vec4 color;\nvoid main() { color = vec4(v, 0.0, 1.0); }\n",
            true,
        );
        assert!(out.starts_with("#version 330\n"), "{out}");
        assert!(
            out.contains("in vec2 v;") && out.contains("out vec4 color;"),
            "{out}"
        );
        assert!(!out.contains("halliday_FragColor"), "{out}");
    }

    #[test]
    fn identifiers_containing_the_words_are_left_alone() {
        let out = run(
            "varying vec2 myvarying;\nvoid main() { float texture2Dx = 1.0; gl_FragColor = vec4(texture2Dx); }\n",
            true,
        );
        assert!(out.contains("in vec2 myvarying;"), "{out}");
        assert!(out.contains("texture2Dx"), "{out}");
    }

    #[test]
    fn a_semicolon_after_a_function_goes_but_a_structs_stays() {
        let out = run(
            "struct Light {\n  vec3 color;\n};\nvoid main(void) {\n  if (true) { gl_Position = vec4(0.0); }\n};\nfloat f() { return 1.0; }  ;\n",
            false,
        );
        assert!(out.contains("struct Light {\n  vec3 color;\n};"), "{out}");
        assert!(
            out.contains("  if (true) { gl_Position = vec4(0.0); }\n}\n"),
            "{out}"
        );
        assert!(out.contains("float f() { return 1.0; }  \n"), "{out}");
        // A function whose opening is in two #ifdef branches still loses its stray `;`.
        let out = run(
            "#ifdef A\nvoid g(float x) {\n#else\nvoid g(float y) {\n#endif\n  float z = 1.0;\n};\nconst float k[2] = float[2](1.0, 2.0);\n",
            false,
        );
        assert!(out.contains("  float z = 1.0;\n}\n"), "{out}");
        assert!(out.contains("float[2](1.0, 2.0);"), "{out}");
    }

    #[test]
    fn a_function_defining_macro_call_loses_its_semicolon() {
        let out = run(
            "#define MS_SHARP(T, F, G, A) \\\n  T F(A x) { \\\n    return G(x); \\\n  }\nvec4 G(vec2 v) { return vec4(v, 0.0, 1.0); }\nMS_SHARP(vec4, F, G, vec2);\nvoid main() { gl_FragColor = F(vec2(0.0)); }\n",
            true,
        );
        assert!(out.contains("MS_SHARP(vec4, F, G, vec2)\n"), "{out}");
        assert!(out.contains("halliday_FragColor = F(vec2(0.0));"), "{out}");
    }

    #[test]
    fn too_long_for_the_buffer_is_refused() {
        let mut out = [0u8; 16];
        assert_eq!(
            translate(b"attribute vec3 a;\nvoid main() {}\n", false, &mut out),
            None
        );
    }
}
