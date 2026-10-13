# Space platforms: why four were lost (data to about 12:05 PDT, 2026-10-13)

**Bottom line.** Two platforms died in flight from Nauvis to Vulcanus (Kestrel, Skylark), each about 4 to 5 minutes after leaving. Two died while parked in Vulcanus orbit with no working guns (Starling, Peregrine), 46 and 103 minutes after arriving or being created. Every one had 3 to 8 gun turrets holding at most 10 to 11 yellow magazines each, no repair packs aboard (Peregrine got 5), and physical damage 2 or 3. Kestrel died with 920 magazines in its hub while 4 of its last 5 turrets were empty. Sunward has fewer guns (2) and has never flown; it had armed guns 11 minutes after creation, and has steady onboard ammo, 36 repair packs and damage 5. Shift06 is live and read to about 12:05. Quotes are respaced where agents ran words together.

| Platform | Created | Left | Lost | Where |
|---|---|---|---|---|
| Starling | 20:09 Oct 12, shift02, game 5h35 | 22:32 (7h55) | 23:31, shift03 (8h50) | parked in Vulcanus orbit |
| Kestrel | 00:24 Oct 13, shift03 (9h37) | 05:10, shift04 (14h04) | 05:15 (14h10) | about 70% of Nauvis to Vulcanus |
| Skylark | 22:56 Oct 12, shift03 (8h17) | 06:44, shift04 (15h32) | 06:48 (15h36) | 43 to 47% of the route, paused |
| Peregrine | 07:01, shift05 (15h47) | never | 08:44 (17h23) | parked in Vulcanus orbit |
| Sunward | 09:54, shift05 (18h29) | not yet | alive | parked in Vulcanus orbit |

## Starling

- Defense: 4 turrets, 10 magazines each (22:20), fed from the hub by inserters, onboard ammo assembler since 21:45. Hub held about 746 magazines at departure. No repair packs. Damage 2.
- The 13-minute crossing destroyed 2 turrets, the collector, a crusher, a furnace and an assembler. Sol at 22:34: "losses include two gun turrets... Needs turret coverage before next trip."
- After arrival (22:45) hub ammo fell from 207 to 0 in 4 minutes. The operator later traced this to hub inserters with destroyed targets throwing items overboard; no agent read showed it. No turret scan exists after 22:35, so the ammo in the 2 surviving turrets is unknown; the empty hub could not refill them.
- The team chose to leave it. Astra 22:49: "I am retiring Starling from flight"; 23:10: "Starling expendable now you landed."
- Hub HP (from `inspect`): 1000 at 22:52, 961 at 23:04, 208 at 23:24. Astra 23:25: "~2 hits from loss. Salvage urgent." Astra deconstructed everything, turrets included, and dropped 157 floors and the thruster to Vulcanus. A medium carbonic asteroid destroyed the hub at 23:31.

## Kestrel

- Defense: 8 turrets, all at 10 magazines from 04:58 to 05:11, fed by one shared belt loop from the hub. Hub 911 magazines at departure, about 11 made per minute aboard. No repair packs. Damage 2, shooting speed 2.
- At 05:11 the thruster tanks read 0% and speed -0.167 at 13% of the route; Sol: "thruster lowest 0%... platforms does not show hp now."
- 05:13:30 to 05:14:20: medium metallic asteroids destroyed 2 collectors, 3 turrets, a crusher, 18 belts and inserters. At 05:14:42, 4 of the 5 remaining turrets were empty; the hub held 920 magazines.
- Hub destroyed about 05:15:17. Astra: "We had ammunition, but the slow shared delivery loop could not keep eight guns fed."
- Haiku took the alerts for a ground attack at 05:13: "Asteroids are hitting the belts and an asteroid collector at (-9..7,-18..-10)... whoever owns that line, watch it."

## Skylark

- Nauvis-orbit science platform for 7.5 hours, rebuilt as a ferry after Kestrel. Defense: 4 turrets beside the hub, each fed by its own hub inserter, 10 to 11 magazines each at 06:45. Hub 482 magazines, about 18.75 per minute made aboard. No repair packs. Damage 2; damage 3 finished at 06:47, mid-flight.
- Astra had planned to wait for damage 3 (06:30) but left at 06:44 near the shift deadline: "Deadline 5 min, return priority."
- First hit 06:44:37. At 06:45:29 Astra paused it at 39%: "taking asteroid hits despite full turret ammo; paused thrust to clear incoming." Paused, it drifted back from 48% to 43%. Astra unpaused it at 06:47:15. By 06:48 six medium asteroids had hit the hub 5 times and it was gone. Hub ammo fell from 495 to 319 in those 3 minutes.

## Peregrine

- Built in Vulcanus orbit to use local steel. Astra at 07:04: "URGENT Peregrine orbit has 4 medium asteroids already. Hub unarmed."
- The guns rocket failed three times (07:16 to 07:23) on a harness bug; it launched at 07:25 with 4 turrets and 22 magazines.
- All 10 turret scans that report status (07:26 to 08:23) show `no_ammo`. Hub ammo was 0 except 17 at 07:56. Where the 22 magazines went is not in the data.
- Hub HP: 1000 (07:17), 924 (07:31), 803 (07:42), 637 (07:50), 390 (08:31), 94 (08:38). Five repair packs arrived about 07:58; Astra: "hub 637HP stayed 637... guns repaired somewhat, all 5 packs gone."
- Astra had agreed with Sol to salvage below 250 HP and dropped 33 floors and the hardware from 08:33. A medium metallic asteroid destroyed it at 08:44.

## Sunward compared

- First cargo carried 2 guns and an ammo assembler. Both turrets had 10 magazines by 10:05, 11 minutes after creation, and in every later scan that read ammo (to 11:47).
- About 188 magazines made per 10 minutes; the consumed counter shows 145 to 187 per 10 minutes in Vulcanus orbit. Hub ammo rose from 154 (11:03) to 427 (11:59).
- Repair packs in hub 16, then 36. Hub HP 911 at 09:58, 1000 since 10:33. Research now damage 5, shooting speed 3.
- Thruster tanks full since 11:32, still paused at Vulcanus. Its 2 turrets are fewer than any lost platform had, and it has not faced a crossing, so nothing here shows it would survive one.

## Gaps in tools and information

- The `platforms` read has no hub health, turret count, turret ammo or entity health, though AGENTS.md says it "shows hub health". Hub HP came only from `inspect` on the hub, almost all by Astra; turret ammo only from a scan with fields.
- About 200 asteroid alerts named no platform, used platform-relative coordinates and ground wording ("no charted nest within 384 tiles").
- `gamedata` has route lengths but no asteroid types, rates per route or orbit, health or resistances. Agents could not work out the turrets or damage a crossing needs and learned of medium asteroids from loss alerts.
- No read showed ammo flow from hub to turrets. On Kestrel the hub count (Astra: "900 ammo reserve") hid empty guns.
- Hub items thrown overboard were invisible until the operator traced them (Starling); `thrown_overboard` came later.
- Platform repair could not be directed; packs go to entities in game order, the hub late. This was explained at 09:13, after Peregrine was gone.
- `platform_schedule` paused a platform mid-route without saying it stays among the asteroids and drifts back.
- A harness launch bug held Peregrine's guns for 9 minutes while asteroids hit its floor and hub.
