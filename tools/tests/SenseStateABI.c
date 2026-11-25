#include "halliday_core.h"
#include <stddef.h>

/* Frozen pre-timed-snapshot public DTO. The additive API must not extend it. */
typedef struct {
    float orientation[4], angular_velocity[3], stick[2];
    float trigger, trigger_proximity, grip_proximity;
    uint32_t buttons, reports, missed;
    float age;
    uint32_t device_ticks;
    uint8_t battery_percent, charging, settled;
} State101;
_Static_assert(sizeof(State101) == sizeof(HallidaySenseState), "State size changed");
_Static_assert(_Alignof(State101) == _Alignof(HallidaySenseState), "State alignment changed");
#define CHECK(field) _Static_assert(offsetof(State101, field) == offsetof(HallidaySenseState, field), "State offset changed: " #field)
CHECK(orientation); CHECK(angular_velocity); CHECK(stick); CHECK(trigger);
CHECK(trigger_proximity); CHECK(grip_proximity); CHECK(buttons); CHECK(reports);
CHECK(missed); CHECK(age); CHECK(device_ticks); CHECK(battery_percent); CHECK(charging); CHECK(settled);
bool (*timed_signature)(const HallidaySense *, HallidaySenseState *, int64_t *) = halliday_sense_state_timed;
