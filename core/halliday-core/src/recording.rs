//! Recordings of raw headset streams, so tracking code can be developed and tested without a
//! headset: record once with `halliday-probe --record`, replay in tests and tools.
//!
//! File layout (all little-endian):
//!
//! ```text
//! header:  b"HALLREC\0"  u32 version (= 1)  u64 wall-clock start, ns since the Unix epoch
//! record:  u8 stream     u64 host time, ns since the recording started (monotonic)
//!          u32 length    [length] raw bytes exactly as received from USB
//! ```

use std::io::{self, Read, Write};

use thiserror::Error;

pub const MAGIC: &[u8; 8] = b"HALLREC\0";
pub const VERSION: u32 = 1;

/// Upper bound on one record, to reject corrupt files before allocating.
pub const MAX_RECORD_LEN: u32 = 16 * 1024 * 1024;

/// Which source a record came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum Stream {
    /// Free-form UTF-8 note (what was being done while recording).
    Note = 0,
    /// Status + IMU interrupt packet.
    Status = 1,
    /// SLAM bulk packet.
    Slam = 2,
    /// Firmware info control reply payload.
    FirmwareInfo = 3,
    /// Distortion calibration control reply payload.
    DistortionCalibration = 4,
}

impl Stream {
    fn from_u8(v: u8) -> Option<Stream> {
        Some(match v {
            0 => Stream::Note,
            1 => Stream::Status,
            2 => Stream::Slam,
            3 => Stream::FirmwareInfo,
            4 => Stream::DistortionCalibration,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub stream: Stream,
    /// Host time in ns since the recording started.
    pub t_ns: u64,
    pub data: Vec<u8>,
}

#[derive(Debug, Error)]
pub enum RecordingError {
    #[error("not a Halliday recording")]
    BadMagic,
    #[error("unsupported recording version {0}")]
    UnsupportedVersion(u32),
    #[error("unknown stream id {0}")]
    UnknownStream(u8),
    #[error("record of {0} bytes exceeds the limit")]
    RecordTooLarge(u32),
    #[error("recording ends in the middle of a record")]
    Truncated,
    #[error(transparent)]
    Io(#[from] io::Error),
}

pub struct Writer<W: Write> {
    out: W,
}

impl<W: Write> Writer<W> {
    pub fn new(mut out: W, start_unix_ns: u64) -> io::Result<Writer<W>> {
        out.write_all(MAGIC)?;
        out.write_all(&VERSION.to_le_bytes())?;
        out.write_all(&start_unix_ns.to_le_bytes())?;
        Ok(Writer { out })
    }

    pub fn write(&mut self, stream: Stream, t_ns: u64, data: &[u8]) -> io::Result<()> {
        let len = u32::try_from(data.len())
            .ok()
            .filter(|&l| l <= MAX_RECORD_LEN)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "record too large"))?;
        self.out.write_all(&[stream as u8])?;
        self.out.write_all(&t_ns.to_le_bytes())?;
        self.out.write_all(&len.to_le_bytes())?;
        self.out.write_all(data)
    }

    pub fn flush(&mut self) -> io::Result<()> {
        self.out.flush()
    }

    pub fn into_inner(self) -> W {
        self.out
    }
}

pub struct Reader<R: Read> {
    input: R,
    pub start_unix_ns: u64,
}

impl<R: Read> Reader<R> {
    pub fn new(mut input: R) -> Result<Reader<R>, RecordingError> {
        let mut magic = [0u8; 8];
        input
            .read_exact(&mut magic)
            .map_err(|_| RecordingError::BadMagic)?;
        if &magic != MAGIC {
            return Err(RecordingError::BadMagic);
        }
        let version = u32::from_le_bytes(read_array(&mut input)?);
        if version != VERSION {
            return Err(RecordingError::UnsupportedVersion(version));
        }
        let start_unix_ns = u64::from_le_bytes(read_array(&mut input)?);
        Ok(Reader {
            input,
            start_unix_ns,
        })
    }

    /// Next record, or `None` at a clean end of file.
    pub fn next_record(&mut self) -> Result<Option<Record>, RecordingError> {
        let mut stream = [0u8; 1];
        if self.input.read(&mut stream)? == 0 {
            return Ok(None);
        }
        let stream = Stream::from_u8(stream[0]).ok_or(RecordingError::UnknownStream(stream[0]))?;
        let t_ns = u64::from_le_bytes(read_array(&mut self.input)?);
        let len = u32::from_le_bytes(read_array(&mut self.input)?);
        if len > MAX_RECORD_LEN {
            return Err(RecordingError::RecordTooLarge(len));
        }
        let mut data = vec![0u8; len as usize];
        self.input.read_exact(&mut data).map_err(truncated)?;
        Ok(Some(Record { stream, t_ns, data }))
    }
}

impl<R: Read> Iterator for Reader<R> {
    type Item = Result<Record, RecordingError>;

    fn next(&mut self) -> Option<Self::Item> {
        self.next_record().transpose()
    }
}

fn truncated(e: io::Error) -> RecordingError {
    if e.kind() == io::ErrorKind::UnexpectedEof {
        RecordingError::Truncated
    } else {
        RecordingError::Io(e)
    }
}

fn read_array<const N: usize, R: Read>(input: &mut R) -> Result<[u8; N], RecordingError> {
    let mut b = [0u8; N];
    input.read_exact(&mut b).map_err(truncated)?;
    Ok(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Vec<u8> {
        let mut w = Writer::new(Vec::new(), 1_700_000_000_000_000_000).unwrap();
        w.write(Stream::Note, 0, b"sitting still").unwrap();
        w.write(Stream::Status, 1_000_000, &[1, 2, 3]).unwrap();
        w.write(Stream::Slam, 2_000_000, &[9; 512]).unwrap();
        w.into_inner()
    }

    #[test]
    fn round_trip() {
        let bytes = sample();
        let mut r = Reader::new(&bytes[..]).unwrap();
        assert_eq!(r.start_unix_ns, 1_700_000_000_000_000_000);
        let records: Vec<Record> = r.by_ref().collect::<Result<_, _>>().unwrap();
        assert_eq!(records.len(), 3);
        assert_eq!(
            records[0],
            Record {
                stream: Stream::Note,
                t_ns: 0,
                data: b"sitting still".to_vec()
            }
        );
        assert_eq!(records[1].stream, Stream::Status);
        assert_eq!(records[1].data, vec![1, 2, 3]);
        assert_eq!(records[2].t_ns, 2_000_000);
        assert_eq!(records[2].data.len(), 512);
    }

    #[test]
    fn rejects_other_files() {
        assert!(matches!(
            Reader::new(&b"GIF89a..........."[..]),
            Err(RecordingError::BadMagic)
        ));
        assert!(matches!(
            Reader::new(&b""[..]),
            Err(RecordingError::BadMagic)
        ));
    }

    #[test]
    fn rejects_newer_versions() {
        let mut bytes = sample();
        bytes[8] = 2;
        assert!(matches!(
            Reader::new(&bytes[..]),
            Err(RecordingError::UnsupportedVersion(2))
        ));
    }

    #[test]
    fn reports_truncation() {
        let bytes = sample();
        let cut = &bytes[..bytes.len() - 10];
        let results: Vec<_> = Reader::new(cut).unwrap().collect();
        assert!(results[..2].iter().all(|r| r.is_ok()));
        assert!(matches!(results[2], Err(RecordingError::Truncated)));
    }

    #[test]
    fn reports_unknown_streams() {
        let mut bytes = sample();
        bytes[20] = 200; // first record's stream id
        let mut r = Reader::new(&bytes[..]).unwrap();
        assert!(matches!(
            r.next_record(),
            Err(RecordingError::UnknownStream(200))
        ));
    }
}
