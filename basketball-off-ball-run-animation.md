# Off-ball basketball run animation

For an **off-ball basketball run**, make the player look like they are reading the court and preparing to receive a pass—not sprinting with exaggerated arm swings. The running gait does the work; the upper body stays controlled.

## Starting stance

- Knees are soft, hips slightly lowered, and torso leans forward a little.
- Chest faces mostly toward the run direction, with a small turn toward the ball.
- Head and eyes look toward the ball or open space, not straight down the lane.
- Elbows stay bent around 70–100 degrees and hands stay near the torso.
- Shoulders are relaxed. Hands should **not** swing beyond the hips or cross the center of the chest.

## Run cycle — step by step

**1. Push-off**

- Rear foot drives through the toes; front leg begins to reach forward.
- Hips move forward with a slight drop and rise, not a large bounce.
- Opposite arm moves back only a small amount; keep the elbow bent.
- Ball-side awareness: rotate the head/chest subtly toward the ball.

**2. Flight / recovery**

- Push-off foot leaves the floor and folds naturally under the body.
- Forward knee drives ahead, but do not lift it like a track sprinter unless the player is in a full sprint.
- Arms counterbalance the legs with a short, restrained swing.
- Hands stay relaxed: palms roughly face inward, thumbs forward.

**3. Foot plant**

- Front foot lands under or only slightly ahead of the hips.
- Knee bends on impact to absorb weight.
- Pelvis shifts over the planted leg.
- Shoulders rotate slightly opposite the hips; this is subtle, not a twist.

**4. Weight transfer**

- Planted leg supports the body as the other knee drives through.
- Torso remains quiet and stable.
- Near arm comes forward only to about ribcage level; rear arm stays behind the torso no farther than the elbow.
- Keep both hands close enough that the player could react to a pass immediately.

**5. Next stride**

- Repeat on the opposite leg.
- Right leg forward → left arm slightly forward.
- Left leg forward → right arm slightly forward.
- The arms should travel in a compact front-to-back path, never side-to-side like waving.

## The key pose sequence

**1. Right foot contact + left arm slightly forward**  
↓  
**2. Weight over right foot + arms nearest the torso**  
↓  
**3. Right toe-off + left knee drives forward**  
↓  
**4. Left foot contact + right arm slightly forward**  
↓  
**5. Weight over left foot + arms nearest the torso**  
↓  
**6. Left toe-off + right knee drives forward**  
↓  
**Repeat**

## Fixing the exaggerated hand waving

- Animate the **upper arm** first, then let the forearm follow; do not keyframe the hands as the driver.
- Reduce arm swing: about 10–20° forward and 15–25° backward is enough for a normal basketball run.
- Keep elbows bent through the entire cycle; locked elbows create a flailing silhouette.
- Keep wrists nearly neutral. Do not add wrist rotation unless the player is signaling or preparing for a pass.
- Remove left/right hand motion: the hands should move mostly front-to-back, close to the ribs.
- Offset arm keys from the legs by half a stride: right leg forward means left arm is forward.
- In Blender’s Graph Editor, flatten or reduce the arm rotation curves, especially shoulder swing and wrist rotation.

## Basketball-specific upper body

**Head and eyes**

- Keep the head stable with very small vertical motion.
- Aim eyes toward the ball, basket, defender, or cut destination.
- Add only a subtle head turn; avoid constant scanning every stride.

**Torso and shoulders**

- Use a small forward lean for a run and a slightly lower stance for a defensive-style cut.
- Let shoulders counter-rotate against the hips by a few degrees.
- Avoid big torso twists—off-ball players need to stay ready to catch.

**Hands**

- Keep hands open but relaxed, fingers naturally curved.
- Bring hands a little closer to chest height only when anticipating a pass.
- For a normal run, hands should stay around lower-rib to hip height.

## Blender workflow

1. Block the legs and pelvis first with contact, down, passing, and up poses.
2. Add a quiet chest and head pass over the completed leg cycle.
3. Add compact shoulder and elbow movement last.
4. Check the animation in silhouette: if the hands read before the legs, reduce the arm motion.
5. Loop it, then check for foot sliding and uneven stride length.

The goal is: **legs create speed, hips create weight, arms only balance, and the upper body stays ready for basketball.**
