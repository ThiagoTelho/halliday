/* Halliday core: C ABI of the Rust halliday-core library, used by the Swift app.
 * Keep in step with core/halliday-core/src/ffi.rs (a unit test checks every function is declared). */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Core library version, a static NUL-terminated UTF-8 string. Do not free. */
const char *halliday_core_version(void);

/* 1 if the USB vendor/product id pair is a PS VR2 headset, otherwise 0. */
int32_t halliday_is_psvr2_headset(uint16_t vendor_id, uint16_t product_id);

/* Host monotonic clock in ns: the clock of CACurrentMediaTime() and display-link timestamps
 * (multiply their seconds by 1e9). */
int64_t halliday_host_time_ns(void);

/* --- Sessions ---------------------------------------------------------------------------- */

typedef struct HallidaySession HallidaySession;

typedef enum {
    HALLIDAY_LINK_SEARCHING = 0,  /* no headset yet, or unplugged; still looking */
    HALLIDAY_LINK_CONNECTED = 1,  /* streams running */
    HALLIDAY_LINK_FULL_SPEED = 2, /* on a USB 2 path, no IMU: needs a USB 3 port */
    HALLIDAY_LINK_REPLAYING = 3,  /* driven by a recording */
    HALLIDAY_LINK_ENDED = 4,      /* non-looping replay finished */
    HALLIDAY_LINK_ERROR = 5,      /* headset present but could not be opened */
} HallidayLinkState;

/* Starts a USB session that connects and reconnects in the background. Never NULL. */
HallidaySession *halliday_session_open_usb(void);

/* Replays a .hrec recording in real time. NULL if the file can't be read. */
HallidaySession *halliday_session_open_replay(const char *path, bool looping);

/* Stops the session and frees it. NULL is ignored. */
void halliday_session_close(HallidaySession *session);

/* A HallidayLinkState value. */
int32_t halliday_session_link_state(const HallidaySession *session);

typedef struct {
    float position[3];         /* meters; x right, y up, -z forward */
    float orientation[4];      /* unit quaternion x, y, z, w */
    float angular_velocity[3]; /* rad/s, head frame */
    int64_t slam_age_ns;       /* age of the SLAM pose the prediction started from */
    uint8_t predicted;         /* 1: gyro-predicted; 0: plain SLAM pose (no IMU yet) */
} HallidayHeadPose;

/* Head pose predicted for host time at_host_ns. False when there is no live tracking. */
bool halliday_session_predict(const HallidaySession *session, int64_t at_host_ns, HallidayHeadPose *out);

/* Additive API: same pose plus eye-centre linear velocity in its recentered world axes.
   motion_flags bit0=linear valid, bit1=angular valid; unknown linear motion is zero.
   The nested legacy pose (including its latest body-local gyro) is unchanged. */
typedef struct {
    HallidayHeadPose pose;
    float linear_velocity[3];
    uint32_t motion_flags;
} HallidayHeadPoseMotion;
bool halliday_session_predict_motion(const HallidaySession *session, int64_t at_host_ns, HallidayHeadPoseMotion *out);

typedef struct {
    uint8_t worn;            /* proximity sensor */
    uint8_t function_button; /* Fn button under the visor */
    uint8_t ipd_mm;          /* IPD dial, 59..72 */
} HallidayHeadsetStatus;

bool halliday_session_status(const HallidaySession *session, HallidayHeadsetStatus *out);

/* Cached connected headset PCB identity (UTF-8 plus NUL); no USB request.
 * False and out unchanged when unavailable or capacity is too short. */
bool halliday_session_headset_identity(const HallidaySession *session, uint8_t *out, uint32_t capacity);

/* full = false: yaw only (keeps the horizon); true: also pitch and roll. */
void halliday_session_recenter(const HallidaySession *session, bool full);

/* Panel brightness 0..1. False without a connected USB headset. */
bool halliday_session_set_brightness(const HallidaySession *session, float brightness);

/* Writes 8 lens calibration floats (the fallback until the headset's were read). */
bool halliday_session_calibration(const HallidaySession *session, float *out);

/* Writes a synthetic recording (a head looking left and right) of `seconds` to path. */
bool halliday_write_synthetic_recording(const char *path, float seconds);

/* --- Tracking cameras ---------------------------------------------------------------------- */

/* The headset's cameras, read by the session while they are switched on: each view's newest
 * bright spots (the controllers' LEDs and whatever else is bright). No picture is kept. A frame
 * holds two cameras' pictures: views 0 and 1; in mode 4 the second kind of frame gives 2 and 3. */
typedef struct {
    float x, y;    /* pixels from the picture's top-left corner, finer than a pixel */
    uint32_t area; /* pixels at or above the threshold */
    uint32_t peak; /* the brightest pixel, 0..255 */
} HallidayCameraSpot;

typedef struct {
    int64_t exposure_host_ns; /* when the cameras exposed (0 until the headset's clock is known) */
    uint32_t counter;         /* one per exposure */
    uint32_t frames;          /* this view's frames since the cameras were switched on */
    uint32_t width, height;   /* the picture's size */
    uint32_t spots;           /* spots found (may be more than were written) */
    uint32_t format;          /* camera_image only: 0 8-bit pixels; 1 BC4 blocks (camera mode 0x10:
                                 the two bottom fisheyes one above the other, width x height pixels) */
} HallidayCameraView;

/* mode: 0 off, 1 the two bottom cameras (normal exposure), 3 all four (rectified), 4 controller
   tracking, 0x10 the two bottom cameras' raw fisheyes (BC4; their spots in fisheye pixels). */
void halliday_session_set_camera(const HallidaySession *session, uint32_t mode, uint8_t threshold);
/* Writes up to max spots, brightest first. False for a view that has had no frame. */
bool halliday_session_camera_view(const HallidaySession *session, uint32_t view, HallidayCameraView *info,
                                  HallidayCameraSpot *out, uint32_t max);
/* Passthrough: keep the bottom cameras' newest picture (in memory only; off drops it), and copy
   it out: left camera then right, side by side, 8 bits a pixel. False when there is none other
   than the one whose counter info holds, or it doesn't fit. */
void halliday_session_set_camera_keep(const HallidaySession *session, bool on);
bool halliday_session_camera_image(const HallidaySession *session, HallidayCameraView *info, uint8_t *out,
                                   uint32_t capacity);

/* --- A controller's place, from the cameras ------------------------------------------------ */

/* One controller's tracker over the two bottom cameras (camera mode 1). Used from one thread. */
typedef struct HallidayHand HallidayHand;

typedef struct {
    float position[3]; /* the controller's IMU in the head's frame at the exposure (x right, y up, z back), m */
    float heading;     /* what the cameras add to the IMU's heading, radians about up */
    uint32_t sightings; /* LEDs matched to spots, counting each picture */
    float rms;          /* how far off they are, pixels */
    float tilt[2];      /* the lean between the IMU's "up" and the head tracking's, radians about the
                           tracking space's x and z: the controller is turned lean * heading * IMU */
} HallidayHandFix;

HallidayHand *halliday_hand_open(bool left);
void halliday_hand_close(HallidayHand *hand);
/* The bottom pair's spots are the raw fisheyes' (camera mode 0x10, their own pixels): true; the
   rectified pair's (modes 1 and 3): false, as a tracker starts. */
void halliday_hand_set_fisheyes(const HallidayHand *hand, bool on);
/* Measured per-headset right raw-camera alignment: rotation vector in radians,
   camera-local x right/y down/z forward. Used for both stereo pairing and raw
   reprojection. Zero restores the generic model. False for NULL, nonfinite or
   >5-degree values; invalid values leave the tracker unchanged. A changed
   alignment resets old pose hypotheses. Apply the same headset profile to both hands. */
bool halliday_hand_set_fisheye_alignment(const HallidayHand *hand, const float *rotation);
/* One exposure: the head's and the controller's orientations in the tracking space at that moment
 * (x, y, z, w), the spots of views 0 and 1 (the bottom pair) and, in camera mode 3, of views 2 and 3
 * (the top cameras; NULL or 0 when missed). True, with out written, when the controller is found. */
bool halliday_hand_update(const HallidayHand *hand, const float *head, const float *controller,
                          const HallidayCameraSpot *left, uint32_t left_count,
                          const HallidayCameraSpot *right, uint32_t right_count,
                          const HallidayCameraSpot *top_left, uint32_t top_left_count,
                          const HallidayCameraSpot *top_right, uint32_t top_right_count, HallidayHandFix *out);

/* --- Sense controllers --------------------------------------------------------------------- */

/* One PS VR2 Sense controller: the app reads its HID reports (Bluetooth or USB) and feeds them
 * in; the core parses them and keeps an orientation from the gyro and the accelerometer.
 * Feeding and reading may be on different threads. */
typedef struct HallidaySense HallidaySense;

/* Buttons and touch sensors, the same bits for both hands: lower is square (left) or cross
 * (right), upper is triangle or circle, menu is Create or Options. */
enum {
    HALLIDAY_SENSE_TRIGGER = 1 << 0,
    HALLIDAY_SENSE_GRIP = 1 << 1,
    HALLIDAY_SENSE_STICK = 1 << 2,
    HALLIDAY_SENSE_PS = 1 << 3,
    HALLIDAY_SENSE_MENU = 1 << 4,
    HALLIDAY_SENSE_LOWER = 1 << 5,
    HALLIDAY_SENSE_UPPER = 1 << 6,
    HALLIDAY_SENSE_TRIGGER_TOUCH = 1 << 8,
    HALLIDAY_SENSE_GRIP_TOUCH = 1 << 9,
    HALLIDAY_SENSE_STICK_TOUCH = 1 << 10,
    HALLIDAY_SENSE_LOWER_TOUCH = 1 << 11,
    HALLIDAY_SENSE_UPPER_TOUCH = 1 << 12,
};

typedef struct {
    float orientation[4];      /* x, y, z, w: controller axes (x right, y up, -z forward) in tracking space */
    float angular_velocity[3]; /* rad/s, controller axes */
    float stick[2];            /* -1..1: x right, y away from the user */
    float trigger;             /* 0..1 */
    float trigger_proximity;   /* 0..1: finger near the trigger */
    float grip_proximity;      /* 0..1: hand near the grip */
    uint32_t buttons;          /* HALLIDAY_SENSE_* */
    uint32_t reports;          /* taken so far */
    uint32_t missed;           /* lost, by the sequence numbers */
    float age;                 /* seconds since the newest report was taken */
    uint32_t device_ticks;     /* the controller's clock at its newest report, thirds of a microsecond */
    uint8_t battery_percent;   /* 5..100 */
    uint8_t charging;
    uint8_t settled;           /* 1 once the orientation has found "up" */
} HallidaySenseState;

/* A handle for the controller with this product id (0x0E45 left, 0x0E46 right); NULL otherwise. */
HallidaySense *halliday_sense_open(uint16_t product_id);
void halliday_sense_close(HallidaySense *sense);
/* The two halves of the IMU calibration (feature report 0x05 read twice), len bytes each. */
bool halliday_sense_calibrate(const HallidaySense *sense, const uint8_t *first, const uint8_t *second, size_t len);
/* One HID input report, report id first. False if it isn't one or fails its checksum. */
bool halliday_sense_report(const HallidaySense *sense, const uint8_t *bytes, size_t len);
/* The newest state. False until a report has been taken. */
bool halliday_sense_state(const HallidaySense *sense, HallidaySenseState *out);
/* Writes the 48-byte feature report (id 0x08) that asks for about 133 reports a second, not 60. */
void halliday_sense_polling_report(uint8_t *out);
/* Writes the 78-byte Bluetooth output report (id 0x31) that sets the tracking LEDs: phase 1
 * blinks (a pulse of period_id x 50 us every cycle_length thirds of a nanosecond, its middle at
 * cycle_position on the controller's clock, thirds of a microsecond), 5 is off. sequence and
 * counter go up by one per report sent, led_sequence when the timing changes. */
void halliday_sense_led_report(uint8_t sequence, uint8_t counter, uint8_t phase, uint8_t led_sequence, uint8_t period_id,
                               uint32_t cycle_position, uint32_t cycle_length, uint32_t host_us, uint8_t *out);
/* Documented 78-byte Bluetooth vibration output. USB output is not inferred. */
void halliday_sense_vibration_report(uint8_t sequence, uint8_t counter, float amplitude, float frequency_hz,
                                     uint32_t host_us, uint8_t *out);
/* Same vibration output with the current connection's LED settings/latch retained.
 * programmed is NULL before LEDs are programmed, otherwise a valid 78-byte report.
 * Returns false for invalid retained packet or NULL out; out is unchanged on failure.
 * The input and output buffers may alias. No LED latch sequence is advanced. */
bool halliday_sense_vibration_report_with_led(uint8_t sequence, uint8_t counter, float amplitude, float frequency_hz,
                                             uint32_t host_us, const uint8_t *programmed, uint8_t *out);
/* Makes where the controller points now the heading yaw (radians about y, 0 forward). */
void halliday_sense_recenter(const HallidaySense *sense, float yaw);

/* The controller's place: the cameras' fixes (the room's frame, meters, at a host time in ns)
 * fused with its accelerometer, asked for at any moment. room_yaw: what the cameras add to the
 * controller's own heading, without which only the fixes are used. A null position in
 * place_fix forgets the place. halliday_sense_place writes three floats each and returns false
 * when the controller wasn't seen lately. */
void halliday_sense_room_yaw(const HallidaySense *sense, float yaw);
void halliday_sense_place_fix(const HallidaySense *sense, int64_t host_ns, const float *position);
bool halliday_sense_place(const HallidaySense *sense, int64_t host_ns, float *position, float *velocity);

/* --- Video formats ------------------------------------------------------------------------- */

typedef struct {
    int32_t projection;    /* 0 equirect 360, 1 equirect 180, 2 fisheye, 3 flat screen */
    int32_t stereo;        /* 0 mono, 1 side by side, 2 top/bottom */
    float fisheye_fov_deg; /* lens field of view for fisheye video */
    float flat_aspect;     /* picture aspect of one eye on a flat screen */
} HallidayVideoFormat;

/* Guesses a video's format from its file name, then fills in the rest from container metadata
 * (projection_kind / view_packing may be NULL), MV-HEVC multiview and the frame size (0 if unknown). */
bool halliday_video_detect(const char *file_name, const char *projection_kind, const char *view_packing,
                           bool multiview, uint32_t width, uint32_t height, HallidayVideoFormat *out);

/* --- Optics ------------------------------------------------------------------------------ */

/* Eye field of view in radians: out[0] left, [1] right, [2] up, [3] down. eye: 0 left, 1 right. */
void halliday_eye_fov(int32_t eye, float *out);

typedef struct {
    float position[2]; /* panel position in the eye's half, 0..1, origin top-left */
    float uv_r[2];     /* where to sample the rendered eye image, per channel; */
    float uv_g[2];     /* outside 0..1 means outside the image (draw black) */
    float uv_b[2];
} HallidayMeshVertex;

/* Builds an eye's distortion mesh of cols x rows cells. Buffers must hold (cols+1)*(rows+1)
 * vertices and cols*rows*6 indices (triangle list). False if a buffer is NULL or too small. */
bool halliday_distortion_mesh(const float *calibration, int32_t eye, uint32_t cols, uint32_t rows,
                              HallidayMeshVertex *vertices, uint32_t vertex_capacity,
                              uint32_t *indices, uint32_t index_capacity);

// --- The bridge to a VR game under Wine (core/halliday-bridge, game_bridge.rs) ---

typedef struct HallidayGameBridge HallidayGameBridge;

/// Meters, +y up, -z forward, the floor at y = 0; orientation x, y, z, w.
typedef struct {
    float position[3];
    uint32_t valid;
    float orientation[4];
    float velocity[3];
    float _pad0;
    float angular_velocity[3];
    /// Halliday's number for the state this pose came from (mod 2^24); passed through by the game side.
    float stamp;
} HallidayBridgePose;

/// OpenVR's legacy controller: buttons as bit (1 << EVRButtonId); axis 0 touchpad, axis 1 trigger.
typedef struct {
    HallidayBridgePose pose;
    uint64_t pressed;
    uint64_t touched;
    float axes[5][2];
    uint32_t connected;
    uint32_t packet;
} HallidayBridgeController;

typedef struct {
    HallidayBridgePose head;
    HallidayBridgeController controllers[2]; // left, right
} HallidayBridgeState;

typedef struct {
    uint32_t eye_width;
    uint32_t eye_height;
    float display_hz;
    float ipd;
    float tangents[2][4]; // per eye: left, right, up, down (left and down negative)
} HallidayBridgeConfig;

typedef struct {
    float position[3];
    float orientation[4]; // quaternion x,y,z,w, host floor coordinates
    float tangents[4]; // canonical left,right,up,down after producer mirroring
} HallidayBridgeProjectionView;
typedef struct {
    uint64_t epoch, frame_index;
    HallidayBridgeProjectionView views[2];
} HallidayBridgeProjectionGeometry;

// Game controller output. The poller has an independent lifetime from the frame host.
typedef struct {
    uint32_t hand, sequence, stop, _pad;
    float amplitude, frequency_hz;
    uint64_t duration_ns; // remaining duration; polling never extends a pulse
} HallidayGameHapticCommand;
typedef struct HallidayBridgeHaptics HallidayBridgeHaptics;
void halliday_bridge_reference_changed(const HallidayGameBridge *bridge);
HallidayBridgeHaptics *halliday_bridge_haptics_open(const char *bridge_path);
uint32_t halliday_bridge_haptics_poll(const HallidayBridgeHaptics *handle, uint64_t now_ns, bool focused,
                                    uint32_t connected_mask, HallidayGameHapticCommand *out, uint32_t capacity);
uint32_t halliday_bridge_haptics_stop(const HallidayBridgeHaptics *handle, HallidayGameHapticCommand *out, uint32_t capacity);
void halliday_bridge_haptics_close(HallidayBridgeHaptics *handle);

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t bottom_up;
    uint32_t slot;
    uint32_t bgra; // 1: pixels are B, G, R, A
    uint32_t see_through; // 1: the picture's alpha is meant: the room may show where it is clear
    float bounds[2][4]; // per eye: u min, v min, u max, v max
    HallidayBridgePose pose;
    uint64_t frame_index;
    uint64_t offsets[2]; // each eye's image, from the start of the mapping
} HallidayBridgeFrame;

// Optional per-eye transfer tags; the existing frame/shared-file layout is unchanged.
#define HALLIDAY_FRAME_COLOR_LEGACY 0
#define HALLIDAY_FRAME_COLOR_LINEAR 1
#define HALLIDAY_FRAME_COLOR_SRGB 2
uint32_t halliday_bridge_frame_color_space(const HallidayGameBridge *bridge, uint32_t slot, uint32_t eye);
/* Caller owns the claimed frame. 0: legacy/no required record, 1: exact valid record,
   -1: required geometry invalid or unavailable: keep the previous complete frame. */
int32_t halliday_bridge_projection_geometry(const HallidayGameBridge *bridge, uint32_t slot,
                                           uint64_t frame_index, HallidayBridgeProjectionGeometry *out);

typedef struct {
    uint64_t frames;
    uint64_t calls;
    uint32_t pid;
    uint8_t name[64];
    uint64_t heartbeat;       // beats about every 250 ms while the runtime is loaded in a game
    uint32_t initialized;     // 1 between the game's VR_Init and VR_Shutdown
    uint32_t quit_acknowledged;
} HallidayBridgeClient;

#define HALLIDAY_BRIDGE_OVERLAYS 8

// What SteamVR's compositor shows besides the game's frames (halliday-bridge `Scene`).
typedef struct {
    float fade_color[4];  // over the game's frames; premultiplied; alpha 0: no fade
    float background_color[4]; // over the compositor's place (skybox, grid)
    float fade_seconds;
    float background_seconds;
    uint32_t grid;        // 1: show Halliday's place instead of the game's frames
    float grid_seconds;
    uint32_t suspended;   // the game stopped drawing on purpose
    uint32_t skybox;      // 0 none, 1 one picture, 2 a stereo pair (left over right)
    uint32_t _pad;
} HallidayBridgeScene;

// One of the game's overlays (halliday-bridge `Overlay`).
typedef struct {
    uint32_t used;
    uint32_t visible;
    uint32_t relative;    // 0: in the room (standing space); 1: relative to device `device`
    uint32_t device;      // 0 head, 1 left hand, 2 right hand
    uint32_t sort_order;
    /// 1: it takes the mouse (Halliday points at it: halliday_bridge_set_pointer).
    uint32_t input;
    float transform[3][4]; // rows of the overlay's pose; the picture lies in its x-y plane, front +z
    float width_m;
    float alpha;
    float color[3];
    float texel_aspect;
    float bounds[4];      // u min, v min, u max, v max
    uint8_t key[64];
    uint8_t file[256];    // a Unix path to show instead of the picture; empty: none
} HallidayBridgeOverlay;

typedef struct {
    uint32_t seq;
    uint32_t width;
    uint32_t height;
    uint32_t _pad;
    uint64_t offset;      // first row (RGBA, top-down, premultiplied), from the start of the mapping
} HallidayBridgePicture;

// The game's window of frames (W14.9; halliday-bridge `present`).
typedef struct {
    uint32_t state;       // 0 off, 1 starting (frames copied too), 2 on, 3 failed
    uint32_t width;       // pixels, the band included
    uint32_t height;
    uint32_t _pad;
} HallidayBridgePresent;

#define HALLIDAY_BRIDGE_PRESENT_BAND 8

// One window frame: below the band, both eyes side by side, rows top-down.
typedef struct {
    uint32_t number;
    uint32_t eye_width;
    uint32_t eye_height;
    uint32_t flipped;     // 1: upside down
    uint64_t frame_index;
    uint32_t texture_type;
    uint32_t _pad;
    HallidayBridgePose pose;
} HallidayBridgePresentFrame;

HallidayGameBridge *halliday_bridge_open(const char *path, const HallidayBridgeConfig *config);
void halliday_bridge_close(HallidayGameBridge *bridge);
/* Mark dead and unlink only this generation; retain mapping for pending GPU readers. */
void halliday_bridge_retire(const HallidayGameBridge *bridge);
void halliday_bridge_publish(const HallidayGameBridge *bridge, const HallidayBridgeState *state);
/* Updates pose/input on every display tick; notify_game alone wakes the game's next frame.
   The shared-memory Header remains v6; legacy publish still always notifies. */
void halliday_bridge_publish_frame(const HallidayGameBridge *bridge, const HallidayBridgeState *state,
                                   bool notify_game);
/* Bits0/1=head linear/angular,2/3=left,4/5=right. Legacy publish APIs remain unchanged. */
void halliday_bridge_publish_frame_with_motion(const HallidayGameBridge *bridge, const HallidayBridgeState *state,
                                             bool notify_game, uint32_t motion_mask);
bool halliday_bridge_begin_read(const HallidayGameBridge *bridge, HallidayBridgeFrame *out);
void halliday_bridge_end_read(const HallidayGameBridge *bridge);
uint8_t *halliday_bridge_base(const HallidayGameBridge *bridge);
uint64_t halliday_bridge_file_size(void);
void halliday_bridge_client(const HallidayGameBridge *bridge, HallidayBridgeClient *out);
/* Raw producer lease: 0 unowned, 1 ready, UINT32_MAX initializing. */
uint32_t halliday_bridge_client_status(const HallidayGameBridge *bridge);
/* Independent-client session generation; zero for a legacy or unready client.
   Added separately so HallidayBridgeClient and the shared v6 layout stay unchanged. */
uint64_t halliday_bridge_client_epoch(const HallidayGameBridge *bridge);
/* Optional producer-owned OpenXR panels, tied to the claimed frame and session. */
typedef struct {
    HallidayBridgePose pose;
    float width_m, height_m;
    uint32_t eye_visibility, flags, order, picture_index, picture_seq;
    uint32_t color_space, bgra, anchor;
} HallidayBridgePanel;
typedef struct {
    uint64_t epoch, frame_index;
    uint32_t count, projection_order, projection_flags, _reserved;
} HallidayBridgePanelBatch;
bool halliday_bridge_panels(const HallidayGameBridge *bridge, uint32_t slot, uint64_t frame_index,
                           HallidayBridgePanelBatch *batch, HallidayBridgePanel *panels, uint32_t capacity);
/* 1 complete, 0 legacy absent, -1 required metadata invalid/unavailable. */
int32_t halliday_bridge_layer_batch(const HallidayGameBridge *bridge, uint32_t slot, uint64_t frame_index,
                                  HallidayBridgePanelBatch *batch, HallidayBridgePanel *panels, uint32_t capacity);
bool halliday_bridge_claim_panel(const HallidayGameBridge *bridge, uint32_t index, uint32_t sequence,
                                HallidayBridgePicture *out);
bool halliday_bridge_scene(const HallidayGameBridge *bridge, HallidayBridgeScene *scene, HallidayBridgeOverlay *overlays);
bool halliday_bridge_claim_picture(const HallidayGameBridge *bridge, int32_t index, uint32_t seen, HallidayBridgePicture *out);
void halliday_bridge_release_picture(const HallidayGameBridge *bridge, int32_t index);
void halliday_bridge_frame_shown(const HallidayGameBridge *bridge, uint64_t interval_ns, bool late);
void halliday_bridge_request_quit(const HallidayGameBridge *bridge);
void halliday_bridge_set_dashboard(const HallidayGameBridge *bridge, bool shown);
void halliday_bridge_set_present(const HallidayGameBridge *bridge, bool enabled, int32_t x, int32_t y);
/// Where a hand points at a game overlay that takes the mouse: overlay index + 1 (0: none), the
/// hand (1 left, 2 right), bit 0 the trigger, u/v 0…1 from the top left, scroll in 1/100 notches.
void halliday_bridge_set_pointer(const HallidayGameBridge *bridge, uint32_t overlay, uint32_t device, uint32_t buttons,
                                 float u, float v, int32_t scroll);
/// Overlay `index`'s height in meters as Halliday shows it.
void halliday_bridge_set_overlay_height(const HallidayGameBridge *bridge, uint32_t index, float meters);
void halliday_bridge_present_status(const HallidayGameBridge *bridge, HallidayBridgePresent *out);
bool halliday_bridge_present_frame(const HallidayGameBridge *bridge, uint32_t number, HallidayBridgePresentFrame *out);
void halliday_bridge_present_seen(const HallidayGameBridge *bridge, uint32_t number);

/* --- Android packages (Quest apps) ------------------------------------------------------- */

/* Reads an APK's AndroidManifest.xml (binary XML, len bytes) and writes UTF-8 text, no terminator:
 * the whole document as text XML (xml), or lines package=, versionName=, versionCode=, native= (a
 * NativeActivity's library) and launcher= (the activity a launcher starts). Returns the text's
 * length (nothing is written when it is more than capacity), or -1 when it isn't a manifest. */
int64_t halliday_apk_manifest(const uint8_t *bytes, size_t len, bool xml, uint8_t *out, size_t capacity);

#ifdef __cplusplus
}
#endif
