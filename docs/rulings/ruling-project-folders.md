# Project folders: on top, lamps inside

**Ruled 29 September 2026**, by voice and by switch: Robert set the three
switches on the mockup page (`agent-project-folders`, session 441562dc) and
said "yes looks great proceed". Nothing earlier ruled on grouping; this adds
to the grid rather than reversing anything.

> *"I just click and drag an agent onto another agent and it becomes, you know,
> goes underneath that folder. That's only for the live grid. The past grid can
> have the chip of the project."*

> *"I guess you just have your projects at the top. And they have their own
> order for the lamps. And they're expanded by default, but you can collapse
> them if you want. And then below that, you would have your other, your
> row-level agents."*

---

## The rules

1. **Folders sit above the loose rows.** No loose row is ever drawn above a
   folder.

2. **Inside a folder, the lamp order is the grid's order, unchanged.**
   `SessionRow.quietRowsLast` runs per folder: green and amber by recency, then
   blue. A lamp turning blue drops to the bottom of its folder, never out of it.
   Read state still never moves a row.

3. **A folder with a green or amber lamp rises to the top of the folders.**
   Switch 1, "Rise to top" (recommended against; ruled for). Folders with a lit
   ask order by their newest asking member; folders without one keep the order
   the user dragged them into, below. Dragging a header sets that user order;
   it cannot hold a folder above one that lights up.

4. **A collapsed folder shows one lamp and a count.** Switch 2, "Lamp and
   count". The header wears its most urgent member's lamp (green or amber, then
   blue) and the number of lit members. Its rows stay hidden: nothing
   uncollapses a folder but the user.

5. **A folder whose agents all finish hides and waits.** Switch 3, "Hide and
   wait". A folder with no member on the grid is not drawn, and is not deleted.
   It goes away only when the user drags its last agent out or deletes it.
   Deleting a folder never ends an agent.

6. **Create by drop.** Dropping a loose agent on the middle of another loose
   agent, and holding, makes a folder of the two. Dropping anywhere on a folder
   joins it; dropping on the loose rows leaves it. Rows are never reordered by
   hand: position is computed.

7. **A fast model names it, and the user can rename it.** One or two words,
   naming the project, not the topic. Double-click the name to edit it.

8. **Past Agents stays one flat list.** Each row carries its folder's chip.
   Reviving an agent returns it to its folder if the folder still exists.

## Why rule 3 went the way it did

The alternative, folders that hold their place, was recommended on the
adaptive-menu literature and on the 14 Sep ruling that a row which moves is hard
to find twice. Robert tried both in the mockup and chose movement: a folder is
a project, and a project with something waiting for you belongs at the top. The
14 Sep ruling still governs rows: hearing a row does not move it.
