//! Guarded legacy producer admission. Shared admission is the authority; HLFT is negotiated.
use crate::{Header, Ordering};
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub struct Lease { pub pid:u32, pub epoch:u64 }
/// Read-only availability, independent of producer admission.
/// # Safety
/// `header` maps at least the v6 header, possibly read-only.
pub unsafe fn present(header:*const Header)->bool {
    let h=unsafe{&*header};h.magic==crate::MAGIC&&h.version==crate::VERSION&&h.halliday_alive.load(Ordering::SeqCst)!=0
}
/// # Safety
/// Full live mapped v6 header. The caller serializes its own connect/cleanup calls.
pub unsafe fn claim(header:*mut Header,pid:u32,fresh_epoch:u64)->Option<Lease>{
 let h=unsafe{&*header};
 if pid==0||fresh_epoch==0||h.magic!=crate::MAGIC||h.version!=crate::VERSION||h.halliday_alive.load(Ordering::SeqCst)==0{return None;}
 let control=unsafe{crate::haptics::extension(header)};
 let timing_available=unsafe{crate::frame_timing::extension(header)}.available();
 if timing_available&&!control.available(){return None;}
 if h.client_initialized.compare_exchange(0,u32::MAX,Ordering::SeqCst,Ordering::SeqCst).is_err(){return None;}
 let timed=timing_available&&control.available();
 // Never override a separate active epoch, even if an inconsistent peer left ready=0.
 if control.available()&&control.client_epoch.load(Ordering::SeqCst)!=0 {
  let _=h.client_initialized.compare_exchange(u32::MAX,0,Ordering::SeqCst,Ordering::SeqCst);return None;
 }
 let epoch=if timed{fresh_epoch}else{0};
 if timed&&!control.begin(pid,epoch){let _=h.client_initialized.compare_exchange(u32::MAX,0,Ordering::SeqCst,Ordering::SeqCst);return None;}
 if h.halliday_alive.load(Ordering::SeqCst)==0 {
  if timed{control.end(epoch);}let _=h.client_initialized.compare_exchange(u32::MAX,0,Ordering::SeqCst,Ordering::SeqCst);return None;
 }
 // The global initializing state admits this writer alone. Keep an old GPU-held reading slot.
 unsafe{(*header).client_pid=pid;}
 h.latest.store(0,Ordering::SeqCst);h.client_frames.store(0,Ordering::SeqCst);
 // A prior window job can still present old pixels; its old band number must not
 // resolve to metadata from the preceding producer after a counter restart.
 for frame in &h.present_frames {frame.number.store(0,Ordering::SeqCst);}
 h.client_initialized.store(1,Ordering::SeqCst);Some(Lease{pid,epoch})
}
/// # Safety
/// Complete mapped header kept alive for this callback.
pub unsafe fn active(header:*const Header,lease:Lease)->bool {
 let h=unsafe{&*header};if h.halliday_alive.load(Ordering::SeqCst)==0||h.client_initialized.load(Ordering::SeqCst)!=1||h.client_pid!=lease.pid{return false;}
 if lease.epoch==0{return !(unsafe{crate::frame_timing::extension(header)}.available()&&unsafe{crate::haptics::extension(header)}.available());}
 let c=unsafe{crate::haptics::extension(header)};
 c.available()&&c.owner_pid.load(Ordering::SeqCst)==lease.pid&&c.client_epoch.load(Ordering::SeqCst)==lease.epoch
}
/// # Safety
/// Full mapped header. Old cleanup callbacks pass their captured lease, not the newest token.
pub unsafe fn release(header:*mut Header,lease:Lease)->bool {
 if !unsafe{active(header,lease)}{return false;}let h=unsafe{&*header};
 if h.client_initialized.compare_exchange(1,u32::MAX,Ordering::SeqCst,Ordering::SeqCst).is_err(){return false;}
 let c=unsafe{crate::haptics::extension(header)};
 if lease.epoch!=0&&(c.client_epoch.load(Ordering::SeqCst)!=lease.epoch||c.owner_pid.load(Ordering::SeqCst)!=lease.pid){
  let _=h.client_initialized.compare_exchange(u32::MAX,1,Ordering::SeqCst,Ordering::SeqCst);return false;
 }
 if lease.epoch!=0{c.end(lease.epoch);}
 h.client_initialized.store(0,Ordering::SeqCst);true
}
#[cfg(test)] mod tests {
 extern crate std;use super::*;
 fn fixture(timed:bool)->std::boxed::Box<[u64;crate::HEADER_BYTES/8]>{
  let mut b=std::boxed::Box::new([0;crate::HEADER_BYTES/8]);let h=b.as_mut_ptr().cast::<Header>();
  unsafe{(*h).magic=crate::MAGIC;(*h).version=crate::VERSION;(*h).halliday_alive.store(1,Ordering::SeqCst);crate::haptics::initialize(h,1);if timed{crate::frame_timing::initialize(h);}}b
 }
 #[test]fn producer_timing_lease_malformed_control_capability_cannot_leave_initializing_admission(){
  let mut b=fixture(true);let h=b.as_mut_ptr().cast::<Header>();
  let p=unsafe{h.cast::<u8>().add(crate::haptics::OFFSET).cast::<crate::haptics::Extension>()};unsafe{(*p).magic=0;}
  assert!(unsafe{claim(h,17,101)}.is_none());assert_eq!(unsafe{(*h).client_initialized.load(Ordering::SeqCst)},0);
 }
 #[test]fn producer_timing_lease_presence_probe_has_no_ownership_or_heartbeat_side_effects(){
  let mut b=fixture(true);let h=b.as_mut_ptr().cast::<Header>();let c=unsafe{crate::haptics::extension(h)};
  for _ in 0..4{assert!(unsafe{present(h)});}
  assert_eq!(unsafe{(*h).client_initialized.load(Ordering::SeqCst)},0);assert_eq!(c.client_epoch.load(Ordering::SeqCst),0);
  assert_eq!(unsafe{(*h).client_heartbeat.load(Ordering::SeqCst)},0);assert!(unsafe{claim(h,29,20)}.is_some());
 }
 #[test]fn producer_timing_lease_duplicate_active_xr_reinit_and_late_cleanup(){
  let mut b=fixture(true);let h=b.as_mut_ptr().cast::<Header>();let a=unsafe{claim(h,17,101)}.unwrap();
  assert!(unsafe{active(h,a)});assert!(unsafe{claim(h,17,102)}.is_none());assert!(unsafe{claim(h,29,103)}.is_none());
  assert!(unsafe{release(h,a)});let next=unsafe{claim(h,17,104)}.unwrap();assert!(!unsafe{release(h,a)});assert!(unsafe{active(h,next)});
  assert!(unsafe{release(h,next)});let xr=unsafe{crate::haptics::extension(h)};assert!(xr.begin(29,200));
  assert!(unsafe{claim(h,17,105)}.is_none());assert_eq!(xr.client_epoch.load(Ordering::SeqCst),200);assert_eq!(unsafe{(*h).client_initialized.load(Ordering::SeqCst)},0);
 }
 #[test]fn producer_timing_lease_legacy_host_stays_epoch_zero_and_failed_claim_preserves_reading(){
  let mut b=fixture(false);let h=b.as_mut_ptr().cast::<Header>();unsafe{(*h).reading.store(2,Ordering::SeqCst);(*h).present_frames[4].number.store(4,Ordering::SeqCst);}
  let a=unsafe{claim(h,17,101)}.unwrap();assert_eq!(a.epoch,0);assert!(unsafe{active(h,a)});assert_eq!(unsafe{(*h).present_frames[4].number.load(Ordering::SeqCst)},0);assert_eq!(unsafe{(*h).reading.load(Ordering::SeqCst)},2);assert!(unsafe{release(h,a)});
  unsafe{(*h).halliday_alive.store(0,Ordering::SeqCst);}
  assert!(unsafe{claim(h,17,102)}.is_none());assert_eq!(unsafe{(*h).client_initialized.load(Ordering::SeqCst)},0);
 }
 #[test]fn producer_timing_lease_ownership_loss_and_initializing_peer_are_not_stolen(){
  let mut b=fixture(true);let h=b.as_mut_ptr().cast::<Header>();unsafe{(*h).client_initialized.store(u32::MAX,Ordering::SeqCst);}
  assert!(unsafe{claim(h,17,101)}.is_none());assert_eq!(unsafe{(*h).client_initialized.load(Ordering::SeqCst)},u32::MAX);
  unsafe{(*h).client_initialized.store(0,Ordering::SeqCst);}let a=unsafe{claim(h,17,102)}.unwrap();
  let c=unsafe{crate::haptics::extension(h)};c.client_epoch.store(999,Ordering::SeqCst);
  assert!(!unsafe{active(h,a)});assert!(!unsafe{release(h,a)});assert_eq!(c.client_epoch.load(Ordering::SeqCst),999);
 }
}
