//! Independent output transport. A separate mapping/poller never borrows the frame host.
use crate::{game_bridge::GameSide, game_haptics::GameHapticCommand};
use halliday_bridge::haptics;
use std::{io, path::Path, sync::atomic::Ordering};

pub struct Receiver {
    side: GameSide,
    epoch: u64,
    sequences: [u32; 2],
    until: [u64; 2],
    heartbeat: u64,
    last_beat: u64,
    previous_clock: Option<(u64, u64)>,
    focus_generation: u32,
}
impl Receiver {
    pub fn open(path: &Path) -> io::Result<Self> {
        Ok(Self {
            side: GameSide::view(path)?,
            epoch: 0,
            sequences: [0; 2],
            until: [0; 2],
            heartbeat: 0,
            last_beat: 0,
            previous_clock: None,
            focus_generation: 0,
        })
    }
    pub fn stop_all(&mut self) -> Vec<GameHapticCommand> {
        self.until = [0; 2];
        (0..2)
            .map(|hand| GameHapticCommand {
                hand,
                stop: 1,
                ..Default::default()
            })
            .collect()
    }
    pub fn poll(&mut self, now: u64, focused: bool, connected: u32) -> Vec<GameHapticCommand> {
        let wall = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos().min(u64::MAX as u128) as u64)
            .unwrap_or(0);
        self.poll_with_wall(now, wall, focused, connected)
    }

    fn poll_with_wall(
        &mut self,
        now: u64,
        wall: u64,
        focused: bool,
        connected: u32,
    ) -> Vec<GameHapticCommand> {
        self.poll_with_hook(now, wall, focused, connected, || {})
    }

    fn poll_with_hook(
        &mut self,
        now: u64,
        wall: u64,
        focused: bool,
        connected: u32,
        before_mailbox_read: impl FnOnce(),
    ) -> Vec<GameHapticCommand> {
        // CLOCK_UPTIME_RAW pauses during Mac sleep. Old pulses must expire across
        // sleep as well: a large wall/uptime divergence consumes pending mailboxes.
        let resumed = self.previous_clock.is_some_and(|(mono, previous_wall)| {
            wall.saturating_sub(previous_wall)
                > now.saturating_sub(mono).saturating_add(500_000_000)
        });
        self.previous_clock = Some((now, wall));
        let h = unsafe { &*self.side.raw_header() };
        let ext = unsafe { haptics::extension(self.side.raw_header()) };
        let focus = unsafe { halliday_bridge::focus::extension(self.side.raw_header()) };
        let generation = focus.generation();
        let mut out = Vec::with_capacity(4);
        if !ext.available() {
            return out;
        }
        ext.clock_ns.store(
            if self.side.halliday_alive() {
                now.max(1)
            } else {
                0
            },
            Ordering::SeqCst,
        );
        let epoch = ext.client_epoch.load(Ordering::SeqCst);
        if epoch != self.epoch {
            for hand in 0..2 {
                if self.until[hand] != 0 {
                    out.push(GameHapticCommand {
                        hand: hand as u32,
                        stop: 1,
                        ..Default::default()
                    });
                }
            }
            self.epoch = epoch;
            self.until = [0; 2];
            self.sequences = [0; 2];
            self.last_beat = now;
            self.heartbeat = h.client_heartbeat.load(Ordering::SeqCst);
        }
        if generation != self.focus_generation {
            // A complete dashboard on/off cycle can happen between polls.
            // Cancel old output but do not drain a fresh post-edge command:
            // its exact mailbox sequence carries the new generation.
            self.focus_generation = generation;
            for hand in 0..2 {
                if self.until[hand] != 0 {
                    out.push(GameHapticCommand {
                        hand: hand as u32,
                        stop: 1,
                        ..Default::default()
                    });
                    self.until[hand] = 0;
                }
            }
        }
        let beat = h.client_heartbeat.load(Ordering::SeqCst);
        if beat != self.heartbeat {
            self.heartbeat = beat;
            self.last_beat = now;
        }
        let active = self.side.halliday_alive()
            && focused
            && !resumed
            && !focus.shown()
            && h.dashboard.load(Ordering::SeqCst) == 0
            && h.client_initialized.load(Ordering::SeqCst) == 1
            && epoch != 0
            && ext.owner_pid.load(Ordering::SeqCst) == h.client_pid
            && now.saturating_sub(self.last_beat) <= 1_000_000_000;
        before_mailbox_read();
        for hand in 0..2 {
            let enabled = active && connected & (1 << hand) != 0;
            if self.until[hand] != 0 && (!enabled || now >= self.until[hand]) {
                self.until[hand] = 0;
                out.push(GameHapticCommand {
                    hand: hand as u32,
                    stop: 1,
                    ..Default::default()
                });
            }
            let Some(request) = ext.read(hand) else {
                continue;
            };
            if request.sequence == self.sequences[hand] {
                continue;
            }
            let producer = focus.producer_epoch.load(Ordering::Acquire);
            let association = focus.matches(epoch, hand, request.sequence, generation);
            // A fresh post-edge request may appear after this poll's focus
            // snapshot. Defer it without consuming its sequence, so the next
            // poll can accept it in the new generation. Likewise for a new
            // producer being claimed while its mailbox is read.
            if focus.generation() != generation
                || ext.client_epoch.load(Ordering::SeqCst) != epoch
                || focus.producer_epoch.load(Ordering::Acquire) != producer
            {
                continue;
            }
            self.sequences[hand] = request.sequence;
            if !enabled
                || request.epoch != epoch
                || ext.client_epoch.load(Ordering::SeqCst) != epoch
            {
                continue;
            }
            if association == Some(false) {
                continue;
            }
            if !request.amplitude.is_finite()
                || !(0.0..=1.0).contains(&request.amplitude)
                || !request.frequency.is_finite()
                || request.frequency < 0.0
                || request.duration_ns > i64::MAX as u64
            {
                continue;
            }
            if request.amplitude == 0.0 || request.duration_ns == 0 {
                self.until[hand] = 0;
                out.push(GameHapticCommand {
                    hand: hand as u32,
                    sequence: request.sequence,
                    stop: 1,
                    ..Default::default()
                });
                continue;
            }
            let Some(until) = request.issued_ns.checked_add(request.duration_ns) else {
                continue;
            };
            if request.issued_ns == 0
                || request.issued_ns > now
                || until <= now
                || now - request.issued_ns > 250_000_000
            {
                continue;
            }
            self.until[hand] = until;
            out.push(GameHapticCommand {
                hand: hand as u32,
                sequence: request.sequence,
                amplitude: request.amplitude,
                frequency_hz: request.frequency,
                duration_ns: until - now,
                ..Default::default()
            });
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::game_bridge::{Config, GameBridge};
    fn fixture() -> (GameBridge, GameSide, Receiver) {
        let path = std::env::temp_dir().join(format!(
            "halliday-focus-{}-{}.shm",
            std::process::id(),
            crate::time::host_time_ns()
        ));
        let host = GameBridge::create(
            &path,
            Config {
                eye_width: 8,
                eye_height: 8,
                display_hz: 72.0,
                ipd: 0.064,
                tangents: [[-1.0, 1.0, 1.0, -1.0]; 2],
            },
        )
        .unwrap();
        let side = GameSide::open(&path).unwrap();
        unsafe { &*side.raw_header() }
            .client_initialized
            .store(1, Ordering::SeqCst);
        let receiver = Receiver::open(&path).unwrap();
        (host, side, receiver)
    }
    #[test]
    fn rapid_focus_cycle_cancels_old_active_and_pending_but_accepts_fresh_first_poll() {
        let (host, side, mut receiver) = fixture();
        let epoch = side.begin_haptics();
        receiver.poll_with_wall(100_000_000, 100_000_000, true, 3);
        assert!(side.send_haptic(epoch, 0, 200_000_000, 0.0, 0.7));
        assert_eq!(
            receiver.poll_with_wall(104_000_000, 104_000_000, true, 3)[0].stop,
            0
        );
        assert!(side.send_haptic(epoch, 1, 200_000_000, 0.0, 0.8));
        host.set_dashboard(true);
        host.set_dashboard(false);
        let commands = receiver.poll_with_wall(108_000_000, 108_000_000, true, 3);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].hand, 0);
        assert_eq!(commands[0].stop, 1);
        assert!(
            receiver
                .poll_with_wall(112_000_000, 112_000_000, true, 3)
                .is_empty(),
            "old pending pulse never replays"
        );
        host.set_dashboard(true);
        host.set_dashboard(false);
        assert!(side.send_haptic(epoch, 1, 200_000_000, 0.0, 0.5));
        let commands = receiver.poll_with_wall(116_000_000, 116_000_000, true, 3);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].hand, 1);
        assert_eq!(
            commands[0].stop, 0,
            "new post-edge Apply before the next receiver poll must start immediately"
        );
    }
    #[test]
    fn focus_tags_survive_generation_wrap_and_reject_stale_producer_and_wrong_sequence() {
        let (host, side, mut receiver) = fixture();
        let first = side.begin_haptics();
        receiver.poll_with_wall(100_000_000, 100_000_000, true, 3);
        let focus = unsafe { halliday_bridge::focus::extension(side.raw_header()) };
        focus
            .state
            .store(u64::from(u32::MAX) << 32, Ordering::SeqCst);
        assert!(side.send_haptic(first, 0, 200_000_000, 0.0, 0.7));
        host.set_dashboard(true);
        assert_eq!(focus.generation(), 1);
        host.set_dashboard(false);
        assert_eq!(focus.generation(), 2);
        assert!(
            receiver
                .poll_with_wall(104_000_000, 104_000_000, true, 3)
                .is_empty()
        );
        let second = side.begin_haptics();
        assert_ne!(first, second);
        assert!(!side.send_haptic(first, 0, 200_000_000, 0.0, 0.7));
        assert!(side.send_haptic(second, 1, 200_000_000, 0.0, 0.5));
        let request = unsafe { haptics::extension(side.raw_header()) }
            .read(1)
            .unwrap();
        focus.requests[1].store(
            (u64::from(request.sequence.wrapping_add(2)) << 32) | 2,
            Ordering::SeqCst,
        );
        assert!(
            receiver
                .poll_with_wall(108_000_000, 108_000_000, true, 3)
                .is_empty(),
            "tag must identify the exact complete mailbox sequence"
        );
        assert!(side.send_haptic(second, 1, 200_000_000, 0.0, 0.5));
        assert_eq!(
            receiver.poll_with_wall(112_000_000, 112_000_000, true, 3)[0].stop,
            0
        );
    }
    #[test]
    fn optional_focus_extension_preserves_old_host_and_old_producer_fallback() {
        let (_host, side, mut receiver) = fixture();
        let first = side.begin_haptics();
        receiver.poll_with_wall(100_000_000, 100_000_000, true, 3);
        let h = unsafe { &*side.raw_header() };
        let ext = unsafe { haptics::extension(side.raw_header()) };
        // An old producer claims HLHP only. A previous new producer's tags
        // cannot make that new legacy epoch look like a tagged command.
        assert!(ext.begin(h.client_pid, first.wrapping_add(1)));
        assert!(ext.write(first.wrapping_add(1), 0, 20_000_000, 0.0, 0.7));
        assert_eq!(
            receiver.poll_with_wall(104_000_000, 104_000_000, true, 3)[0].stop,
            0
        );
        // An old host has no optional HLFC magic. New producers keep the
        // original HLHP behavior rather than rejecting otherwise valid output.
        unsafe {
            side.raw_header()
                .cast::<u8>()
                .add(halliday_bridge::focus::OFFSET)
                .cast::<u32>()
                .write(0)
        };
        let second = side.begin_haptics();
        assert!(side.send_haptic(second, 1, 20_000_000, 0.0, 0.5));
        assert!(
            receiver
                .poll_with_wall(108_000_000, 108_000_000, true, 3)
                .iter()
                .any(|v| v.hand == 1 && v.stop == 0)
        );
    }
    #[test]
    fn focus_edge_and_fresh_apply_during_a_poll_defer_without_consuming_the_new_sequence() {
        let (host, side, mut receiver) = fixture();
        let epoch = side.begin_haptics();
        receiver.poll_with_wall(100_000_000, 100_000_000, true, 3);
        let commands = receiver.poll_with_hook(104_000_000, 104_000_000, true, 3, || {
            host.set_dashboard(true);
            host.set_dashboard(false);
            assert!(side.send_haptic(epoch, 1, 200_000_000, 0.0, 0.8));
        });
        assert!(commands.iter().all(|v| v.stop != 0));
        let commands = receiver.poll_with_wall(108_000_000, 108_000_000, true, 3);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].hand, 1);
        assert_eq!(
            commands[0].stop, 0,
            "a command from the new generation must not be lost to the old poll snapshot"
        );
    }
    #[test]
    fn transport_expiry_focus_generation_and_disconnect() {
        let path = std::env::temp_dir().join(format!(
            "halliday-independent-haptics-{}.shm",
            std::process::id()
        ));
        let host = GameBridge::create(
            &path,
            Config {
                eye_width: 8,
                eye_height: 8,
                display_hz: 72.0,
                ipd: 0.064,
                tangents: [[-1.0, 1.0, 1.0, -1.0]; 2],
            },
        )
        .unwrap();
        let side = GameSide::open(&path).unwrap();
        let h = unsafe { &*side.raw_header() };
        h.client_initialized.store(1, Ordering::SeqCst);
        let ext = unsafe { haptics::extension(side.raw_header()) };
        let mut receiver = Receiver::open(&path).unwrap();
        let a = side.begin_haptics();
        assert_ne!(a, 0);
        assert!(receiver.poll(100_000_000, true, 3).is_empty());
        assert!(side.send_haptic(a, 0, 20_000_000, 160.0, 0.7));
        let commands = receiver.poll(104_000_000, true, 3);
        assert_eq!(commands.len(), 1);
        assert_eq!(commands[0].duration_ns, 16_000_000);
        assert!(receiver.poll(108_000_000, true, 3).is_empty());
        assert_eq!(receiver.poll(121_000_000, true, 3)[0].stop, 1);
        assert!(side.send_haptic(a, 1, 50_000_000, 0.0, 1.0));
        assert!(receiver.poll(125_000_000, false, 3).is_empty());
        assert!(receiver.poll(130_000_000, true, 3).is_empty());
        assert!(side.send_haptic(a, 1, 50_000_000, 0.0, 1.0));
        assert_eq!(receiver.poll(134_000_000, true, 3)[0].stop, 0);
        assert_eq!(receiver.poll(138_000_000, true, 1)[0].stop, 1);
        assert!(receiver.poll(142_000_000, true, 3).is_empty());
        // Old-hand mailboxes cannot replay after a new session claims output.
        let b = side.begin_haptics();
        assert_ne!(a, b);
        assert!(receiver.poll(146_000_000, true, 3).is_empty());
        assert!(!side.send_haptic(a, 0, 10_000_000, 0.0, 1.0));
        assert!(side.send_haptic(b, 0, 10_000_000, 0.0, 1.0));
        assert_eq!(receiver.poll(150_000_000, true, 3)[0].stop, 0);
        side.end_haptics(a);
        assert_eq!(ext.client_epoch.load(Ordering::SeqCst), b);
        side.end_haptics(b);
        assert_eq!(receiver.poll(154_000_000, true, 3)[0].stop, 1);
        assert!(!ext.write(0, 0, 10, 0.0, 1.0));
        // A sleeping Mac's uptime does not advance with wall time. No stale
        // long pulse may start again when the display and poller resume.
        let c = side.begin_haptics();
        receiver.poll_with_wall(200_000_000, 1_000_000_000, true, 3);
        assert!(side.send_haptic(c, 0, 5_000_000_000, 0.0, 1.0));
        assert!(
            receiver
                .poll_with_wall(204_000_000, 61_004_000_000, true, 3)
                .iter()
                .all(|v| v.stop != 0)
        );
        assert!(
            receiver
                .poll_with_wall(208_000_000, 61_008_000_000, true, 3)
                .is_empty()
        );
        assert!(side.send_haptic(c, 0, 100_000_000, 0.0, 1.0));
        assert_eq!(
            receiver.poll_with_wall(212_000_000, 61_012_000_000, true, 3)[0].stop,
            0
        );
        drop(receiver);
        drop(side);
        drop(host);
    }
}
