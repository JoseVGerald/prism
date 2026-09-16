# Natural running and dribbling in Blender

This guide gives Claude a precise checklist for making a basketball player run and dribble with believable weight, balance, and ball control. The animation should feel like one coordinated action—not a run cycle with a separate ball animation attached.

## Goal

- Create a natural, game-ready looping run-and-dribble animation.
- Make the legs drive the run, the pelvis carry the body weight, the torso stabilize the player, and the arms balance the motion.
- Make the dribble respond to the run cadence without being perfectly mechanical.
- Keep the player looking ahead, ready to pass or react.

## Before animating

### 1. Set the scene

- Set the frame rate to `24 fps` or match the game’s animation frame rate.
- Use a `16-frame` loop for a normal running dribble at 24 fps; use a `12-frame` loop for a faster sprint dribble.
- Place the floor at `Z = 0` and make sure the ball has a known radius.
- Add a floor contact marker beneath each foot and beneath the ball’s bounce location.
- Use the rig’s root, pelvis/hips, spine/chest, head, clavicles, upper arms, forearms, hands, thighs, shins, feet, toes, and finger controls if available.

### 2. Make the controls clean

- Create separate action layers or animation groups for: `root/pelvis`, `legs`, `spine/head`, `arms`, `ball`, and `fingers`.
- Start with the root and legs only. Do not animate hands or the ball first.
- In the Graph Editor, use linear curves temporarily for blocking; polish with Bezier curves only after timing works.
- Lock accidental hand rotation axes if the rig allows it. Excessive wrist keys are a common reason hands look like they are waving.

## Build the run first

### 3. Block the two foot contacts

For a 16-frame loop:

- Frame `1`: right foot contacts the floor; left foot is behind and beginning toe-off.
- Frame `5`: right leg supports the body; pelvis is lowest over the right foot.
- Frame `9`: left foot contacts the floor; right foot is behind and beginning toe-off.
- Frame `13`: left leg supports the body; pelvis is lowest over the left foot.
- Frame `17`: repeat frame 1 exactly for a seamless loop.

### 4. Pose the legs

At each contact:

- Place the contact foot under or only slightly in front of the pelvis. Do not let it land far ahead like a stiff walk.
- Bend the planted knee slightly on impact; never lock it straight.
- Keep the heel low at contact, then roll through the foot toward the toes.
- Let the trailing leg extend behind the body, then fold naturally at the knee during recovery.
- Keep stride length consistent between right and left sides unless intentionally making a directional run.

### 5. Add root and pelvis weight

- Move the root forward at a steady rate so the character actually travels; do not fake speed only with cycling legs.
- At frame 5, shift the pelvis slightly over the right planted foot.
- At frame 13, shift the pelvis slightly over the left planted foot.
- Lower the pelvis a small amount at each support pose, then raise it during the passing pose.
- Add only a small vertical bounce. Basketball runs are athletic and springy, but should not look like hopping.
- Rotate the hips a few degrees with the stride. Keep the movement subtle.

### 6. Remove foot sliding

- In every planted-foot range, hold that foot in world space.
- Check the animation from the side and from behind.
- If the planted foot moves across the floor, adjust root forward travel or use an IK foot lock.
- Make toe-off happen only after the body passes above the planted foot.

## Add the upper body

### 7. Add torso stability

- Lean the torso slightly forward from the hips—about `5–12 degrees` for a normal run.
- Keep the chest much steadier than the pelvis.
- Counter-rotate the shoulders a few degrees against the hips.
- Do not make the torso twist strongly from side to side.
- Keep the head stable with only a very small rise and fall.
- Aim the eyes and head toward the court, basket, teammate, or defender—not down at the ball.

### 8. Make the arms natural, not flagrant

- Animate shoulder movement first, then elbow movement, then the hand.
- Keep elbows bent roughly `70–100 degrees` through most of the cycle.
- Limit shoulder swing for a normal basketball run: about `10–20 degrees` forward and `15–25 degrees` backward.
- Keep hands inside the player silhouette: they should not swing wide outside the hips or cross far across the chest.
- Keep the forearms close to the ribs and moving mostly forward/back, not side-to-side.
- Keep wrists nearly neutral. Do not add wrist flicks unless the hand is controlling the basketball.
- Offset the arms from the legs: right leg forward means left arm is slightly forward; left leg forward means right arm is slightly forward.
- Check in silhouette. If the hands draw more attention than the legs, reduce the shoulder and wrist curves.

## Add the ball and dribbling hand

### 9. Choose a ball-side rhythm

- Pick the dribbling hand: for example, right hand.
- A standard running dribble can bounce once per stride or once every two strides depending on speed and desired style.
- Do not make every bounce perfectly identical. Add very small timing and height variation only after the base loop is clean.
- Keep the ball bounce beside the running lane, slightly ahead of the dribbling-side foot—not directly under the body and not far out to the side.

### 10. Block one ball bounce

For a right-hand dribble on a 16-frame run:

- Frame `1`: ball is controlled at right hip/waist height; right elbow is bent.
- Frame `3`: hand pushes the ball down using the palm/fingertips; elbow begins extending.
- Frame `5`: ball is descending beside the right leg; the hand follows down without grabbing it.
- Frame `7`: ball contacts the floor and squashes slightly.
- Frame `8`: ball rebounds upward; remove hand contact.
- Frame `10`: right hand reaches down and forward to receive the ball; fingers are spread naturally.
- Frame `12`: fingertips control the top/side of the rising ball; elbow bends to absorb momentum.
- Frame `14`: ball returns near hip height and transitions directly into the next push.
- Frame `17`: repeat frame 1.

### 11. Animate ball physics visually

- Use a fast downward motion and a fast initial rebound.
- Use a small squash at floor impact, then a brief stretch when the ball leaves the ground.
- Keep the bounce lower for a fast sprint and somewhat higher for a relaxed run.
- Do not leave the ball at the hand for a long pause; the player should guide, push, receive, and immediately redirect it.
- Use a clean contact state: either the hand controls the ball or it does not. Avoid visible hand/ball clipping.

### 12. Make the hand control believable

- At the push, contact the upper/back side of the ball; the fingers guide it downward.
- During free flight, let the hand follow the ball briefly, then separate.
- On the catch, meet the upper/side of the rising ball with the fingertips first.
- Bend the elbow to absorb the rebound; do not let the ball appear to stop abruptly.
- Keep the wrist relaxed and aligned with the forearm.
- Animate fingers subtly: open slightly before receiving, curl gently during control, then relax. Do not overanimate every finger.

## Synchronize the run and dribble

### 13. Layer the cycles correctly

- The run cadence and ball cadence should be related but not mirror each other exactly.
- Do not let the player stop, rise sharply, or change stride length just because the ball touches the floor.
- The ball-side shoulder may lower a little during the downward push, but the chest should remain stable.
- The opposite arm still counterbalances the legs; it should not freeze because the other hand is dribbling.
- Ensure the dribble does not force the hand to swing behind the body or far above shoulder height.

### 14. Check every camera angle

- Side view: check forward momentum, foot sliding, forward lean, and ball height.
- Front view: check that knees track naturally and hands do not swing outside the hips.
- Back view: check pelvis side shift and shoulder counter-rotation.
- Top view: check that the ball travels beside the dribbling lane and the body does not zig-zag.
- Game camera: check that the ball is visible, but the animation still reads naturally from a distance.

## Polish pass

### 15. Use the Graph Editor

- Smooth sudden spikes in wrist, hand, clavicle, and shoulder rotation curves.
- Reduce large alternating peaks in hand location curves; this removes waving.
- Keep planted-foot transform curves flat during contact.
- Make root forward translation continuous and smooth.
- Use gentle ease-in/ease-out for the pelvis and chest; use sharper timing only for ball-floor contact.
- Compare left and right curves for accidental asymmetry.

### 16. Add small secondary motion last

- Add a subtle jersey/shoulder follow-through only if the rig supports it.
- Add tiny head stabilization delay after the pelvis moves.
- Add slight finger motion and a small wrist follow-through on the push.
- Do not add extra bounce, arm swing, or torso twisting to make it feel “alive.” Natural restraint is better.

### 17. Final game checks

- Test at normal speed, half speed, and in a loop for at least 10 repetitions.
- Check that frame 1 and frame 17 match exactly for a seamless loop.
- Test different forward speeds; scale root motion before stretching every limb pose.
- Verify that no foot penetrates the floor, no ball clips through the floor, and no hand clips through the ball.
- Ensure the player can transition cleanly from dribble-run into idle dribble, stop, crossover, pass, gather, layup, and shot animations.

## Paste-ready prompt for Claude

```md
Improve the existing Blender running-and-dribbling animation so it feels like a natural basketball player running with the ball. Preserve the rig, character, court scale, and loop length unless a timing change is necessary.

Work in this order:

1. Inspect the loop from side, front, back, top, and game-camera views. Identify foot sliding, locked knees, excessive hand waving, large wrist rotation, rigid torso motion, ball clipping, and mismatched run/dribble timing.
2. Block a believable run cycle before changing the ball: feet contact under the hips, knees bend on impact, the trailing leg pushes through the toe, and the pelvis shifts over the planted leg.
3. Keep each planted foot fixed in world space through its contact phase. Correct root forward motion or use IK foot locks to remove foot sliding.
4. Give the pelvis a small vertical rise/fall and subtle side shift, with a slight forward torso lean. Keep chest and head stable; do not create a large bounce or twist.
5. Fix the arms: animate shoulders first, elbows second, hands last. Keep elbows bent around 70–100 degrees. Reduce shoulder swing to a compact basketball-run range. Keep hands close to the ribs, mostly moving forward/back, never flailing side-to-side or far outside the hips.
6. Keep wrists nearly neutral except when the dribbling hand pushes or receives the ball. Remove unnecessary wrist and finger keys that make the hands wave.
7. Add the dribble after the run works. Keep the ball beside and slightly ahead of the dribbling-side foot. Animate: controlled at hip height → hand pushes down → free descent → small squash on floor contact → rebound → fingertips receive → elbow absorbs → immediate next push.
8. Do not make the ball pause in the hand. During free flight, the hand must separate cleanly from the ball. At reception, fingertips meet the ball before the elbow bends.
9. Make ball-floor contact sharp and readable, but keep pelvis, chest, and stride timing continuous. The legs must not change their run pattern every time the ball bounces.
10. In the Graph Editor, flatten excessive hand-location and wrist-rotation curves, smooth shoulder/elbow curves, keep planted-foot curves flat, and keep root movement continuous.
11. Loop-test the animation repeatedly. Make the first and final frames match exactly. Verify no foot sliding, no ball or hand clipping, balanced arm motion, stable head motion, and a natural run rhythm.

The final animation should communicate: legs create speed, hips create body weight, torso stays controlled, arms balance the run, and the dribbling hand guides the ball with relaxed athletic control.
```
