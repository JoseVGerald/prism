# Basketball camera half-court transition

For a 2K-style basketball camera, keep following the player or ball continuously. When possession changes, smoothly rotate the camera to the opposite court-relative side instead of snapping it when the ball crosses half court.

## Core camera behavior

```text
Camera follows player position
+ camera offset depends on attack direction
+ camera smoothly interpolates to the new offset
```

```pseudo
attackDirection = teamIsAttackingRight ? 1 : -1

desiredCameraPosition =
    followTarget.position
    - courtForward * backDistance * attackDirection
    + courtRight * sideOffset
    + worldUp * cameraHeight

desiredLookTarget =
    followTarget.position
    + courtForward * lookAheadDistance * attackDirection

camera.position = SmoothDamp(
    camera.position,
    desiredCameraPosition,
    positionVelocity,
    0.25 seconds
)

camera.rotation = SmoothLookAt(
    camera.rotation,
    desiredLookTarget,
    0.3 seconds
)
```

## Possession flip

Trigger the flip only after confirmed possession changes—not when the ball simply crosses half court.

```pseudo
if possessionChanged:
    teamIsAttackingRight = !teamIsAttackingRight
```

The camera’s desired offset then moves to the other side of the player. Smooth interpolation makes it orbit and rotate about 180 degrees while it continues following the active player.

## Transition rules

- Trigger after a steal, defensive rebound, turnover, or inbound after a made basket.
- Keep `followTarget` active throughout the transition; never freeze camera tracking.
- Rotate 180 degrees over roughly `0.25–0.45 seconds` with ease-in-out smoothing.
- Keep height and zoom stable during the flip; rotate the court-relative offset only.
- Add a `0.75–1.0 second` cooldown to prevent repeated flipping during loose balls.
- During fast breaks, reduce follow smoothing so the camera catches up sooner.
- Maintain more empty screen space in front of the offense than behind it.

## Camera states

```text
NORMAL OFFENSE
  → confirmed possession changes
  → CAMERA FLIPPING
  → new direction reached
  → NORMAL OFFENSE
```

## Ready-to-paste implementation prompt

```md
Make the basketball camera smoothly transition like NBA 2K when possession changes.

- The camera must always follow the active ball handler or ball-focused target, including during the transition.
- Do not snap the camera when the ball crosses half court.
- Flip the camera only after confirmed possession changes: steal, defensive rebound, turnover, or inbound after a made basket.
- Store an `attackDirection` value of `1` or `-1`.
- Position the camera at a court-relative offset behind the attacking team.
- When `attackDirection` changes, smoothly interpolate the camera position and rotation to the opposite court-relative offset.
- Rotate roughly 180 degrees over 0.25 to 0.45 seconds using ease-in-out smoothing.
- Keep camera height, zoom, and follow target stable during the flip.
- Add a 0.75 to 1 second flip cooldown so loose balls cannot cause repeated camera rotations.
- During fast breaks, increase follow responsiveness while preserving smooth camera rotation.
- The result should feel like the 2K camera: the player remains followed, the court rotates smoothly, and the controlled offense consistently attacks toward the same screen direction.
```
