//! A small JSON reader for SteamVR Input's files (action manifest and bindings): no allocator, the
//! document's nodes in a fixed array, strings left in the source (escapes are kept as written;
//! SteamVR's files use none in names and paths).

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Kind {
    Object,
    Array,
    String,
    Number,
    Bool,
    Null,
}

#[derive(Clone, Copy, Debug)]
pub struct Node {
    pub kind: Kind,
    /// The value's text (a string without its quotes).
    pub start: u32,
    pub end: u32,
    /// The member's key in the parent object (empty for array items and the root).
    pub key_start: u32,
    pub key_end: u32,
    /// First child + 1, next sibling + 1 (0: none).
    pub first: u32,
    pub next: u32,
}

const EMPTY: Node = Node {
    kind: Kind::Null,
    start: 0,
    end: 0,
    key_start: 0,
    key_end: 0,
    first: 0,
    next: 0,
};

pub const MAX_NODES: usize = 4096;

pub struct Doc<'a> {
    pub src: &'a [u8],
    pub nodes: &'a mut [Node; MAX_NODES],
}

struct Parser<'a, 'b> {
    src: &'a [u8],
    pos: usize,
    nodes: &'b mut [Node; MAX_NODES],
    count: usize,
}

impl Parser<'_, '_> {
    fn ws(&mut self) {
        while self.pos < self.src.len() && self.src[self.pos].is_ascii_whitespace() {
            self.pos += 1;
        }
    }

    fn string(&mut self) -> Option<(u32, u32)> {
        if self.src.get(self.pos) != Some(&b'"') {
            return None;
        }
        let start = self.pos + 1;
        let mut i = start;
        while i < self.src.len() && self.src[i] != b'"' {
            if self.src[i] == b'\\' {
                i += 1;
            }
            i += 1;
        }
        if i >= self.src.len() {
            return None;
        }
        self.pos = i + 1;
        Some((start as u32, i as u32))
    }

    fn value(&mut self, depth: u32) -> Option<usize> {
        if depth > 64 || self.count >= MAX_NODES {
            return None;
        }
        self.ws();
        let index = self.count;
        self.count += 1;
        self.nodes[index] = EMPTY;
        let c = *self.src.get(self.pos)?;
        match c {
            b'{' | b'[' => {
                let object = c == b'{';
                self.pos += 1;
                self.nodes[index].kind = if object { Kind::Object } else { Kind::Array };
                let mut last: Option<usize> = None;
                loop {
                    self.ws();
                    if self.src.get(self.pos) == Some(&if object { b'}' } else { b']' }) {
                        self.pos += 1;
                        break;
                    }
                    let key = if object {
                        let k = self.string()?;
                        self.ws();
                        if self.src.get(self.pos) != Some(&b':') {
                            return None;
                        }
                        self.pos += 1;
                        Some(k)
                    } else {
                        None
                    };
                    let child = self.value(depth + 1)?;
                    if let Some((ks, ke)) = key {
                        self.nodes[child].key_start = ks;
                        self.nodes[child].key_end = ke;
                    }
                    match last {
                        Some(l) => self.nodes[l].next = child as u32 + 1,
                        None => self.nodes[index].first = child as u32 + 1,
                    }
                    last = Some(child);
                    self.ws();
                    match self.src.get(self.pos) {
                        Some(b',') => self.pos += 1,
                        Some(b'}') | Some(b']') => {}
                        _ => return None,
                    }
                }
            }
            b'"' => {
                let (s, e) = self.string()?;
                self.nodes[index] = Node {
                    kind: Kind::String,
                    start: s,
                    end: e,
                    ..EMPTY
                };
            }
            _ => {
                let start = self.pos;
                while self.pos < self.src.len() && !b",}] \t\r\n".contains(&self.src[self.pos]) {
                    self.pos += 1;
                }
                let text = &self.src[start..self.pos];
                let kind = match text {
                    b"true" | b"false" => Kind::Bool,
                    b"null" => Kind::Null,
                    _ if !text.is_empty() => Kind::Number,
                    _ => return None,
                };
                self.nodes[index] = Node {
                    kind,
                    start: start as u32,
                    end: self.pos as u32,
                    ..EMPTY
                };
            }
        }
        Some(index)
    }
}

impl<'a> Doc<'a> {
    /// Parses `src` into `nodes`; the root is node 0.
    pub fn parse(src: &'a [u8], nodes: &'a mut [Node; MAX_NODES]) -> Option<Doc<'a>> {
        let mut p = Parser {
            src,
            pos: 0,
            nodes,
            count: 0,
        };
        p.value(0)?;
        Some(Doc {
            src,
            nodes: p.nodes,
        })
    }

    pub fn text(&self, n: usize) -> &'a [u8] {
        let node = self.nodes[n];
        &self.src[node.start as usize..node.end as usize]
    }

    pub fn key(&self, n: usize) -> &'a [u8] {
        let node = self.nodes[n];
        &self.src[node.key_start as usize..node.key_end as usize]
    }

    pub fn kind(&self, n: usize) -> Kind {
        self.nodes[n].kind
    }

    /// The children of an object or array.
    pub fn children(&self, n: usize) -> Children<'_, 'a> {
        Children {
            doc: self,
            next: self.nodes[n].first,
        }
    }

    /// An object's member by key.
    pub fn get(&self, n: usize, key: &[u8]) -> Option<usize> {
        if self.nodes[n].kind != Kind::Object {
            return None;
        }
        self.children(n).find(|&c| self.key(c) == key)
    }

    /// An object member's string value.
    pub fn string(&self, n: usize, key: &[u8]) -> Option<&'a [u8]> {
        self.get(n, key)
            .filter(|&c| self.kind(c) == Kind::String)
            .map(|c| self.text(c))
    }
}

pub struct Children<'d, 'a> {
    doc: &'d Doc<'a>,
    next: u32,
}

impl Iterator for Children<'_, '_> {
    type Item = usize;
    fn next(&mut self) -> Option<usize> {
        if self.next == 0 {
            return None;
        }
        let i = self.next as usize - 1;
        self.next = self.doc.nodes[i].next;
        Some(i)
    }
}

/// Compares ASCII text ignoring case (SteamVR's paths are case-insensitive).
pub fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.eq_ignore_ascii_case(y))
}
