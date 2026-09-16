# Basketball team AI and difficulty prompt

Use this prompt for the game AI:

---

Build better **5-on-5 basketball AI** for both my team and the opposing team. The game should feel fair, readable, and basketball-smart. My team stays at the **same player overall ratings and attributes** on every difficulty. Only the opposing team becomes more organized, faster to react, and better at using its players as difficulty rises.

## Core rule

- Keep the player shooting system the same on every difficulty.
- Use the existing timing meter and **green-release** mechanic unchanged.
- Do not secretly change shot timing windows, player shooting ratings, rim size, ball physics, or make/miss odds by difficulty.
- Difficulty comes from AI decision-making, positioning, rotations, communication, and execution—not cheating.

## AI behavior for both teams

**Offense**

- Space the floor: corners stay occupied, wings stay available, and players do not crowd the ball handler.
- Move without the ball: cut after passes, fill open perimeter spots, relocate when a teammate drives, and set useful screens.
- Choose shots intelligently: open layup/dunk, open jumper, open three, then reset the offense if no advantage exists.
- Avoid forcing heavily contested shots early in the shot clock.
- Pass out of traps and double teams.
- Recognize mismatches, open cutters, and open corner shooters.

**Defense**

- Stay between the ball handler and the basket.
- Help on drives, then recover to the most dangerous open shooter.
- Switch only when appropriate; do not switch every screen blindly.
- Protect the paint first, then contest the closest high-value shooter.
- Box out after shots and transition back after turnovers.
- Avoid impossible steals, instant blocks, teleporting recoveries, or knowing user input before it happens.

## Difficulty levels

### Junior Varsity — forgiving opponent

- Opponent runs basic offense with slower reads and occasional poor spacing.
- Help defense is late and rotations are imperfect.
- They take some open shots but occasionally settle for low-quality mid-range attempts.
- Screen navigation, closeouts, rebounding, and transition defense are less consistent.
- My team’s AI is competent: it spaces, passes, cuts, and helps normally.

### Varsity — balanced opponent

- Opponent recognizes open shooters, drives, cutters, and simple mismatches.
- Runs pick-and-roll actions, basic off-ball screens, and sensible drive-and-kick plays.
- Help defense arrives on time and recovers to shooters with normal human reaction speed.
- Takes mostly good shots and resets the offense when defended well.
- My team AI remains exactly the same overall rating and uses the same basketball logic.

### Elite League — smart, disciplined opponent

- Opponent plays organized basketball, not superhuman basketball.
- Identifies repeated user habits: over-helping, reaching, leaving corners, or failing to defend screens.
- Uses stronger play selection: pick-and-roll, backdoor cuts, flare screens, post mismatches, and drive-and-kick passes.
- Rotates quickly but believably, communicates switches, tags rollers, and closes out under control.
- Values shot quality: attacks open lanes, finds the extra pass, and avoids bad contested shots unless the clock is low.
- Has better transition spacing, box-outs, rebounding effort, and late-game clock management.
- Never receives boosted attributes, altered green windows, scripted makes, or unfair reaction times.

## Shot selection rules

Use the same shot-selection priorities for both teams:

**1. Open layup, dunk, or cut to the rim**  
↓  
**2. Open corner or wing three**  
↓  
**3. Open mid-range shot**  
↓  
**4. Create a drive-and-kick or pick-and-roll advantage**  
↓  
**5. Reset and run another action**  
↓  
**6. Forced late-clock shot only when necessary**

## Fairness checks

- My team has the same ratings, speed, stamina, shooting, and green-meter rules on every difficulty.
- The opponent should improve through better decisions, not stat boosts.
- A fully green user shot should remain a green shot at every level.
- A bad, contested opponent shot should still be a bad shot at every level.
- The player should be able to beat Elite League by recognizing patterns, making smart rotations, and executing well.

The goal is: **Junior Varsity feels forgiving, Varsity feels competitive, Elite League feels smarter—not rigged.**
