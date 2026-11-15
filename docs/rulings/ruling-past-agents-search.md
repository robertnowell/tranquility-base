# Past Agents search: one kept index, the passage on the row

**Ruled 15 November 2026**, by voice, across three turns of session 9356b639.
The research and the measurements behind it are in that session's pages
`past-agents-search-plan` and `2026-11-15-past-agents-search-redesign`.

> *"Preparing search appears nearly every time I search, and that doesn't
> really make sense. It shouldn't need to prepare search every time. If ever,
> that should happen in background on startup, not every search."*

> *"I should be able to sort search recent versus relevant. A lot of the time
> I want to see recents first."*

> *"I want to be able to see why each is ranking, because often the title
> alone is not a good description of the relevant context that has been
> matched."*

> *"30 days is not enough. Search should index over like 90 days at least but
> really all time. Why would there be a limit to my ability to find recent
> agents or context? One year makes sense to me."*

Asked whether search results may include agents the grid is showing:
> *"Yes, for search results only. The list with no search text stays as it is."*

---

## The rules

1. **The index is kept, never rebuilt.** It lives on disk, one row for each
   message. A pass reads only the bytes each log has grown by. The app runs a
   pass at launch and about once a minute. Opening Past Agents prepares
   nothing. Before this, 38 of 38 measured openings deleted and rebuilt the
   index (median 568 ms, worst 8 s).

2. **A search never waits for a pass.** While the first build runs, a search
   answers from the part that exists and the line under the list says how far
   the build is.

3. **A result shows why it matched, on the row.** The passage, who said it
   (you, the agent, a report, a summary), the matched words emphasised, and
   how many more passages matched. Never a session id or a path. Something
   said in the conversation is shown before a page written about it.

4. **Recent or Relevant, and Recent unless he chooses otherwise.** Recent
   orders agents by the newest thing said that matched. Relevant orders by
   where the words matched: the name, then his words, then the agent's. The
   choice is remembered.

5. **Search covers every log on disk.** No window. The limit is the harness:
   Claude Code deletes a log after `cleanupPeriodDays` (30 by default, 365 on
   Robert's Mac).

6. **A search may answer with an agent the grid is showing.** This changes
   the 12 August rule that the grid and the list never share an agent, for
   search results only. The list with no search text is unchanged: thirty
   days, and only the agents the grid did not draw.

7. **No model and no network.** Keyword search (BM25). Embedding search was
   researched and not adopted: a result it finds has no words to point at,
   which breaks rule 3.

## Not done yet

- A cold archive walk takes about 30 seconds on Robert's Mac, most of it
  parsing Codex rollouts whole. It runs off the main thread, once per launch;
  until it lands, a search does not list agents older than thirty days.
- A row cannot yet be opened to read its other matching passages.
- Other installs keep thirty days of logs unless `cleanupPeriodDays` is raised.
  The app does not offer to raise it.
