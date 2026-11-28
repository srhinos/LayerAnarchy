# Layer Anarchy

## 0.2.4

- New option **Host while queued**: tick it to keep hosting while you're queued or listed in the group finder. Off by default, so hosting still pauses then.

## 0.2.3

- When you can't host right now, LayerSwap and Bulo players see you as busy or Host off, instead of "not updated".
- Hosting pauses while you're listed in the group finder, queued in the dungeon finder or queued for a battleground, so a guest joining your group can't cost you your place.

## 0.2.2

- Your chat channels keep their numbers (General 1, Trade 2 and so on), even when Layer Anarchy joins its channels first or while you're in a dungeon.
- When another layer addon is loaded, the window has a button that disables it and reloads.
- Optional minimap button, off by default: turn it on under the cog's options. Click shows or hides the window; drag it around the minimap's edge. It's a standard LibDBIcon button, so button collectors like HidingBar pick it up.

## 0.2.1

- The nameplate flash while the layer shows "?" is now a single blink half a second after you phase, instead of a second-long flash repeated every 10 seconds.

## 0.2.0

**Layers you can recognise and go back to**
- Layer letters now mean something. Layer Anarchy recognises a layer from the creatures around you, so coming back to one shows its old letter and how long you were away ("Layer B · back after 4m"). A "?" means it hasn't confirmed which layer yet; while it shows, nameplates flash on for a moment now and then to read the creatures around you.
- Click the layer name for a list of the layers in your zone, when you were last on each, and the hosts known to be there. Pick one to swap straight back to it.

**Swapping**
- Every network is asked at once, then more players every few seconds until everyone reachable has been asked. The status shows how many.
- "Ask AutoLayer" appears after about 12 seconds; "Search more" appears only when another /who needs your click.
- Swapping in combat no longer opens the Group Finder.
- Hosts on your own layer no longer count as found.
- The box resets as soon as you leave the host's group.
- Invites from friends and guildmates are left alone during a swap.

**Hosting**
- Friends who whisper "inv" or say "layer" in guild chat are no longer invited by mistake.
- Hosting no longer fills chat with group messages about strangers.
- Fixes for /reload while hosting, and for failed invites holding up your own swap.

**Also**
- Controller support: bind "Controller focus" to put the controller on the box.
- No longer switches off for LayerNumber or PartyLens.
- Many smaller fixes.

## 0.1.1

- Now on Wago.

## 0.1.0

First release.

- One-click layer swap through LayerSwap, AutoLayer, VoidNet and Forever Layer Hop at once.
- Hosts for all four networks.
- Swap in combat, while dead, whenever the game allows.
- Learns the real hourly swap limit from your own swaps and shows a reset countdown after a refusal.
- Network panel: who's on each network, your swaps and hosting, for the last hour or the session.
- Turns itself off if another layer addon is loaded.
