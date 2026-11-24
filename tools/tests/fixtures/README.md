# Sense regression data

`hand-tracking-worker.json` contains detected spot coordinates, IMU orientations
and relative exposure timing. Frame counters start at zero, exposure time is
rebased to one second and world head translation is zeroed. It contains no
images, hardware identity, buttons, room position or wall-clock timestamp.

`sense_fisheye_alignment.txt` in `core/halliday-core/tests/fixtures` likewise
contains anonymized scalar spot/IMU samples. The measured relative camera
rotation is used only by tests and an explicitly matching local profile; it is
never installed as a universal calibration.
