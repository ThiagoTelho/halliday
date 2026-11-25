/// Describes an existing orientation; publishing a tag never rotates the host
/// pose, pointer or OpenVR reference. Values match optional HLCF v1 metadata.
enum GameControllerPoseFrame: UInt32 {
    case legacy = 0
    case senseAim = 1
}
