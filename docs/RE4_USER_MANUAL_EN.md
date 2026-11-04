# Armor Variant Manager (RE4) — User Manual

Resident Evil 4 (2023 Remake) support in the universal Armor Variant Manager package — the same
download also serves Monster Hunter Wilds / Rise and detects the game by itself.

Turn parts of your character's model on and off — by hand, or automatically when something
happens in game (low HP, aiming, taking a hit, a melee kill…).

It works by toggling **materials** on the character's four meshes (body / head / hair / armor).
It does not touch model files, does not use the game's costume system, and writes nothing
except its own config files.

---

## 1. Requirements & install

**You only need [REFramework](https://github.com/praydog/REFramework).** Nothing else —
no REFramework C#, no reframework-d2d, no .pak. On RE4 it runs as pure Lua: the preview DLL and
REFF page in the package are for Monster Hunter Wilds and stay idle here; REFF is not used on RE4.

1. Install REFramework for RE4 (`dinput8.dll` in the game folder).
2. Unzip the universal package **into the game's root folder**, so the files land as:

```
<RE4 folder>/reframework/autorun/ArmorVariantManager.lua
<RE4 folder>/reframework/autorun/ArmorVariantManager_Core/…
```

3. Start the game, open the REFramework menu (**Insert** by default), and find
   **Script Generated UI → Armor Variant Manager (RE4)**.
   If the game was already running, press **Reset Scripts** in the REFramework window first.

There is a **中文** checkbox at the top of the panel if you prefer Chinese.

### Does it need a character mod?

No — it runs on the stock characters too (everything is visible by default, so nothing
looks different until you turn things off). It is most useful with a custom character model
that has separable materials.

> **Important if you share configs:** a config stores **material names**, so it only makes
> sense on the model it was made for. See [§10 Sharing](#10-sharing-your-setup).

---

## 2. Two-minute tour

```
Armor Variant Manager (RE4) v4.3.4
  [ ] 中文
  ch0_a0z0  |  HP 83.4%  |  In battle          <- who you are + which conditions are true now
  [Reset config]

  Quick switch                                 <- everyday use lives here
  [Default          ▼] Full outfit
  ▼ Basic state groups (manual): none active
      [ ] Hide Hood
      [Skirt off      ▼] Lower clothes
  ▼ Advanced state groups (rule-driven): Face
      Face   [x] Auto   -> driven by rule: Normal

  ▼ Full outfit - edit                         <- build things here (fold it away afterwards)
  ▼ State groups - edit
  ▼ Material notes
  ▼ Save / load
```

Top half = **use**. Bottom half = **build**. You can collapse the bottom half and forget it.

---

## 3. The two kinds of "outfit"

| | What it is | Its entries are called |
|---|---|---|
| **Full outfit** | One complete look — every material has an explicit on/off | **presets** |
| **State group** | A set of **mutually exclusive** states that override *specific* parts on top of the full outfit | **states** |

Use a **full outfit preset** when you want to switch the whole look at once
(*Default*, *Jacket off*, *Battle damaged*).

Use a **state group** when you want one small thing to change while everything else stays
as it is (*Hide hood*, *Face: normal / hurt / low HP*). A state group only "claims" the
materials you tell it to; anything it does not claim is left to the full outfit.

Several state groups can be active at the same time (`Hide hood` **and** `Face: hurt`) —
that is the whole point of splitting them up. Inside one group, only one state is active.

> **A note on the `armor` slot.** On some models it isn't always present — it can be tied to
> which *skin/costume* is currently active rather than to anything you do in-game. It also
> commonly duplicates material names from the `body` slot, because armor is often exported
> as a full re-export of the body rather than just the covered parts. Neither is a problem:
> this mod keys everything by slot, so `body/Jacket` and `armor/Jacket` never collide, and
> switching skins is handled automatically, the same as any other model change.
>
> **Armor mirrors body**, at the top of *Full outfit - edit*, is **on by default** for exactly
> this reason: armor and body sharing one material set is the common case. It makes armor
> always copy whatever body ends up showing, matched by material name, with zero setup and
> no need to touch armor again as you keep editing body. Turn it off only if your armor and
> body genuinely use different materials. If just **some** materials overlap rather than
> all of them, leave the checkbox off and use the **`Armor mesh loaded`** condition (§15)
> on a state group instead, to hide just those.

---

## 4. Walkthrough A — hide a part (the simplest thing)

Goal: a switch that hides the hood.

1. **State groups - edit** → type a name in *New state group name* → **New state group**.
   A state called `1` is created and selected for you.
2. The editor opens. Pick the part in *Part filter* (or leave *All parts*) and find the
   material — the **Locate** button in *Material notes* (§9) helps if you don't know which is which.
3. Click a material's button to cycle it: `—` → `off` → `on`.
   - `—` = this state doesn't care, the full outfit decides
   - `off` / `on` = this state claims that material and forces it
4. Set the hood material to `off`. Done — it is already applied.
5. Fold everything up. In **Quick switch → Basic state groups** you now have a checkbox:
   ticked = hood hidden, unticked = the full outfit decides again.

> A group with only one state shows as a **checkbox**; with several states it shows as a
> **dropdown** (with `(none)` to switch the whole group off).

---

## 5. Walkthrough B — a full outfit preset

1. **Full outfit - edit** → **New preset**. It snapshots how your character looks *right now*,
   so you always start from something working.
2. Turn materials off/on until it looks right. Rename it in *Current preset name* → **Rename**.
3. Switch presets any time from **Quick switch**.

**Overwrite this preset from current look** re-snapshots the preset from whatever is on
screen — handy after you install a model update, or after fiddling with state groups.

---

## 6. Walkthrough C — automatic: face changes when you get hit

This is the flagship use. Goal: the face swaps to a "hurt" variant for one second whenever
you take damage, and to a "low HP" variant while you are in the danger zone.

1. Make a state group `Face` with three states: `Normal`, `Hurt`, `Low HP`
   (each one turns on its own face material and off the others).
2. Open that group's **Condition rules** section.
3. **Target state** → `Hurt`.
4. **Add a condition** → *Condition:* `HP decreased`, *Value:* `yes` → **Add condition**.
5. **Hold after conditions end (sec)** → `1` → **Apply**.
6. **Target state** → `Low HP` → **Add a condition** → `HP vital tier` `==` `Danger` → **Add condition**.
7. Order them: in the state list, use **Up** / **Down** to put `Hurt` above `Low HP`,
   and leave `Normal` at the bottom.

Now: hit → face is `Hurt` for one second → falls back to `Low HP` if you are in danger,
otherwise back to `Normal` (the manual value).

Two mechanisms just did the work — they are worth understanding, so §7 and §8 explain them.

---

## 7. Hold — making split-second conditions visible

Roughly half of the available conditions are **instantaneous**: `Shooting`, `Pulling trigger`,
`Parry`, `Fatal kill`, `Hit taken`, `Landing`, `HP decreased`… they are true for one or two
frames. Without help you would never see the variant.

**Hold after conditions end (sec)** fixes that. The timer starts **the moment the conditions
stop holding**:

- While the conditions hold, the state stays on and the timer does **not** count down.
- When they stop, it stays on for N more seconds, then releases.
- Conditions holding again re-arms it.

So a condition that lasts 5 seconds with Hold = 2 is visible for 7 seconds total.

Hold applies to the **whole rule** — "A AND B, then hold N seconds". Suggested values:

| Condition | Hold |
|---|---|
| Shooting / Pulling trigger | 0.3 – 0.5 |
| Parry / Perfect parry / Dodging / Quick turn / Landing | 0.5 – 1 |
| Hit taken / Upper body hit / HP decreased | 1 – 2 |
| Fatal kick / Fatal kill (blood, dirt afterwards) | 2 – 3 |
| Crouching, Running, In battle, Burning, HP% … | 0 (they already last) |

Giving Hold to an already-lasting condition just makes it linger after you let go — usually
not what you want.

---

## 8. Priority — the state list order

**When several states in the same group hold at once, the one highest in the list wins.**
Reorder with **Up** / **Down**; the list *is* the priority table.

Rule of thumb: **the more momentary or more special a state is, the higher it goes.**
Constants go at the bottom.

The rules overview shows what is happening:

```
By priority (top wins):
  1. HP decreased = yes -> Hurt  [hold 1]   (in effect)
  2. HP vital tier == Danger -> Low HP      (holds, but outranked above)
```

- **in effect** — this is what you are seeing
- **holds, but outranked above** — its conditions are true, but something higher won
- **target state is gone, never fires** — leftover rule pointing at a deleted state; delete it

A state with **no** rule never fires on its own — it is your manual fallback.

---

## 9. Auto — pausing the rules

Every layer that has rules gets an **[x] Auto** checkbox in Quick switch.

- **Auto on** — rules drive it. No manual control is offered, because rules always win.
- **Auto off** — rules are ignored for that layer, and a dropdown appears so you can pin it
  by hand. Pick `(none)` to make the layer stop touching anything at all.

Use it for screenshots, for trying outfits on without your face flickering, or while
rebuilding a group. Paused layers are listed under Quick switch as **Auto paused: …** so you
don't forget one and think the rules broke.

---

## 10. Material notes & Locate

Model material names (`Metal3`, `BeltRibon_In`) tell you nothing. **Material notes** lets you
label them once, per character, and the labels then show up everywhere you edit.

**Locate** temporarily shows *only* that material for about 3 seconds — everything else in
that part is hidden, so whatever is still visible is the thing you clicked. It is a preview:
nothing is saved.

---

## 11. Save / load, and the safety nets

**Save / load** is a manual slot system — name it, save it, load it later.
Loading replaces your current config, so it asks for confirmation.

**Slots are shared across characters.** The list shows your own slots first, then other
characters' with a prefix (`ch3_a8z0 / my setup`). Loading one **copies** it into the current
character; the source is untouched. Handy when two characters use the same model, and still
useful when they don't — you keep the whole structure (state groups, states, conditions,
rules, priority, hold) and only need to re-capture the materials.

You can only delete your own slots, and saving always writes to your own file.

Two automatic restore points, under **Automatic restore points**:

- **Restore to before last delete/overwrite** — written right before anything destructive
- **Restore to config as loaded this session** — what was on disk when you started

Old configs are upgraded automatically when read, and only written back once you change
something — so an untouched file stays untouched.

---

## 12. Sharing your setup

Configs live in `reframework/data/ArmorVariantManager/<character>.json`, e.g.
`ch0_a0z0.json` for Leon. Send that file; the recipient drops it in the same folder.

**They must have the same model mod, in the same version.** The config refers to materials by
name, so on a different model the names don't line up and you get:

```
[ ] My preset  [material mismatch, skipped]
```

That message means the full outfit preset was judged to belong to a different model, so it
was skipped instead of applying a half-broken look. State groups don't warn — they just
silently ignore materials they can't find.

Quick way to check whose model is actually loaded: open **Material notes** — it lists the
material names of the model that is live right now.

Whether the model was installed as loose files or packed into a `.pak` makes **no difference**
— this mod reads the runtime mesh, not files. If a packed version "doesn't work", the usual
cause is load order: something else overrode it and a different model is actually in game.

---

## 13. Troubleshooting

| Symptom | What it means |
|---|---|
| `No controlled character found` | You're in a menu / cutscene, or not in control of a character yet. |
| `No BodyUpdater found` | The current character isn't a playable one. |
| `material mismatch, skipped` | That preset was made for a different model (or model version). See §12. |
| A state group does nothing | Its materials don't exist on this model, or the group is set to `(none)`, or another group claims the same materials — check **Conflicting state groups on these materials**. |
| Rules stopped working | Check for **Auto paused** under Quick switch. |
| Two rules both say they hold | Only the top one is **in effect** — see §8. |
| `UI draw error …` | A drawing error was caught and contained; other mods are unaffected. Please report it with the message. |
| Everything reverts after a cutscene | It shouldn't — the mod re-applies automatically when the game resets materials. If it persists, report it. |

**Reset config** wipes the current character's config back to a single captured preset
(a backup is written first). It only appears when the character has its own config.

---

## 14. File locations

```
reframework/autorun/ArmorVariantManager.lua              the script
reframework/autorun/ArmorVariantManager_Core/            its modules
reframework/data/ArmorVariantManager/<character>.json    your config, one file per character
reframework/data/ArmorVariantManager/GlobalSettings.json language + known characters
reframework/data/ArmorVariantManager/backup/             restore points and named slots
```

Uninstall = delete the script, the `ArmorVariantManager_Core` folder, and the package's other files
(`reframework/plugins/ArmorVariantManager_Portrait.dll`, `reframework/reff/plugins/monkeysama.avm/`,
`natives/STM/ArmorVariantManager/`). Your configs stay in `reframework/data/` unless you delete them too.

---

## 15. Condition reference

34 conditions. **★ = instantaneous, needs Hold** (see §7).

**Combat**

| Condition | Notes |
|---|---|
| In battle | The game's own combat flag. |
| Aiming while moving or turning | Only true while you actually move the character **or** the camera; standing perfectly still turns it off. |
| Aiming while stationary | Aiming or holding the knife up while planted. (Engine name is "Wheel"; nothing to do with boats.) |
| Melee attacking ★ | Knife attacks only. |
| Shooting ★ | A shot actually left the gun. |
| Pulling trigger ★ | The fire button — also true when dry-firing. |
| Reloading | |
| Changing weapon | |
| Throwing ★ | |
| Parry ★ / Perfect parry ★ | |
| Fatal kick ★ / Fatal round kick ★ / Fatal kill ★ | Finishers. |
| Dodging ★ | |

**Posture & movement**

| Condition | Notes |
|---|---|
| Crouching / Walking / Running | Normal running lights **Running**. |
| Quick turn ★ / Landing ★ | |
| Jumping / Falling / On ladder / Hook shot / On boat | |

**Damage & status**

| Condition | Notes |
|---|---|
| Hit taken ★ | True when a normal attack connects — **even for zero damage**. Does **not** fire for grabs/cinematic attacks, even though they drain HP. |
| Upper body hit ★ | Includes flashbangs. |
| Burning | |
| Invincible | |

**HP**

| Condition | Notes |
|---|---|
| HP% | Number, with `<= < >= > ==`. Good for tiers: put the narrow rule above the wide one. |
| HP vital tier | The game's own grading (`Fine`, `Danger`, `Dead` — the dropdown lists whatever this build declares). **Not** the same as HP%: at 54.9% HP the game still says `Fine`. |
| HP decreased ★ / HP increased ★ | True on the frame HP changes. Pair with Hold. `HP decreased` also covers grab/cinematic damage, which `Hit taken` misses — put both in one rule with **Any one holds (OR)** for full coverage. |

**Model**

| Condition | Notes |
|---|---|
| Armor mesh loaded | True while the `armor` slot exists — on some models this tracks the current skin/costume rather than any in-game action. Not momentary, no Hold needed. Use it to auto-hide `body` materials that an armor mesh covers (see the note in §4). |

Some engine flags were tested and left out because they never lit up during testing
(sprint, guarded, enemy attack sign, elevator, suspension bridge, flashlight, safe room…).
They may simply need scenes that weren't visited — say the word if you want one back.

---

## 16. Credits

Ported from the MHRise / MHWorld "Armor Variant Manager" and rewritten for RE4's
`chainsaw.*` player model (four fixed mesh slots instead of Monster Hunter's armour parts).

Verified on **Leon (`ch0_a0z0`)** and **Ada (`ch3_a8z0`)** — same code, no per-character branches.
Ashley's playable sections are untested.

Bug reports are much more useful with: the exact panel message, your character, and
the config file.
