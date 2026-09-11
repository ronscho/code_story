# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `:boundaries` accepts modules of your own, alongside the repos
  `:auto_boundary` detects: `boundaries: [MyApp.Accounts]`. The collector always
  handled an arbitrary list — suppress the interior, tag the entry — but
  `do_start/1` overwrote it with the detected repos, so a declared boundary was
  discarded without a word.

  Detecting repos is a good default and not the whole story. Where a functional
  core ends and a boundary begins is a *design decision*, not something a tool
  can sniff out of a module: a context, an adapter, a client wrapper are all
  boundaries by intent. With one declared, a trace reads the way the system was
  designed — the core expanded, the crossing as a single edge.

  Declared and detected add up; `auto_boundary: false` leaves only what was
  declared.

### Added

- Calls made by processes the traced code **spawns** are now part of the trace.
  `:set_on_spawn` hands the trace flags to every process a traced one starts, so
  the recursion costs no code; the collector keeps a tree per process while
  their events interleave, and folds each child's tree back into its parent.

  This matters most where the work is not in the calling process at all. A
  Dataloader batch resolves through `Task.async_stream`, so on a GraphQL request
  the queries actually being run were exactly the part that went missing — while
  the trace still looked complete, which is the worse failure.

  Placement follows what is knowable. If the spawning call is one the tracer was
  already inside, the child's tree hangs underneath it. If it is not — the common
  case, because the spawn usually happens in framework code — there is no node to
  hang it on, and the child's tree takes its place in the parent's own sequence
  at the point in time the spawn occurred.

  Repeated children collapse through the existing `:fold_repeats`, so a batch
  runner's two dozen bookkeeping calls read as `×24` rather than two dozen lines.

- A `:follow` option traces processes that were already running, by registered
  name or pid: `follow: [MyApp.Cache]`. Spawn-following covers what the traced
  code starts; this covers what it merely talks to — a supervised GenServer, a
  registry, a channel — where a `GenServer.call` otherwise shows the caller
  blocking and nothing of the work it asked for.

  A target may be named any way OTP allows (a pid, a registered atom,
  `{:global, term}`, `{:via, Registry, key}`) or given as a zero-arity function
  returning a pid, for a process carrying no name at all. ⚠ `:trace.process/4`
  rejects a registered name, unlike the legacy `:erlang.trace/3`, so targets are
  resolved through `GenServer.whereis/1` before attaching — and a target that
  cannot be reached, including a pid that has already died, is reported rather
  than silently ignored.

  ⚠ Following attaches to a *process*, not to a conversation. Everything that
  process does inside the window is recorded, including work other callers asked
  it for — worth knowing before pointing `follow:` at a busy server.

### Changed

- Collecting now waits, briefly and with a ceiling, for spawned processes to
  exit before it stops tracing. A process's exit event is ordered behind its own
  calls, so a child seen to exit has delivered everything — and a child that
  outlives the traced region is given up on rather than allowed to hold the
  trace. The single-process ordering argument does not carry across processes,
  so this replaces it rather than adding to it.

### Fixed

- A traced region now records **every** top-level call, not only the first. The
  collector treated the first root returning as the end of the story and
  discarded everything after it, which made `tell/0` + `stop/0` unable to do the
  one thing it exists for -- bracketing a region -- and silently truncated the
  block form, where the output still looked complete.

  The effect was largest where the tool is most useful. When the entry point is
  framework code the tracer does not follow (a GraphQL runtime, a Plug
  pipeline), your own functions are reached as a *sequence* of top-level calls;
  the first one to return ended the trace before the interesting ones ran. In
  one Absinthe request this meant a trace containing the schema's `context/1`
  callback and nothing else -- no middleware, no resolver, no repo call.

  `status` still reports `{:completed, tree}` as soon as there is a complete
  tree to hand out; it simply no longer means "stop listening".

### Changed

- `narrate/2` returns one root per top-level call instead of only the first, and
  its documentation no longer describes the old limitation. ⚠ A caller that
  pattern-matched `[root] = tree` on a `fun` with several top-level calls will
  now match a longer list.

- Calls left open when the region ends -- a `throw`, a `raise`, or a bracket
  closed mid-call -- are kept in the tree rather than dropped. A call that never
  came back is usually the one worth seeing.

## [0.2.0] - 2026-08-29

### Changed

- The trace's semantic colors are now **bold** for legibility on both light and dark
  terminals (and projectors). Meaning never rests on color — structure, `=>`,
  `name:`, `×N`, and indentation carry it — so this is purely a readability bump.

- Boundary (`Repo.*`) calls now render with their known Ecto parameter names across the
  detail dial, like user functions: `:outline` shows names only
  (`Repo.get!(queryable, id)`, `Repo.preload(struct, preloads)`), `:short_story`/`:novel`
  show `name: value` (`Repo.get_by!(queryable: MailSettings, filters: [event_id: 1])`),
  and the return drops at `:outline` only. Names come from a small built-in table (no
  Ecto dependency) covering the common callbacks — `get`, `get_by`, `all`, `one`,
  `insert`, `update`, `delete`, `preload`, and `aggregate`; other functions fall back
  to positional values.

### Added

- User-defined function calls now render as a compact inline signature —
  `Mod.fun(name: value, …) => return` on one line — when the line fits the new
  `:width` budget (default 100), the same signature style boundary (`Repo.*`)
  calls already use. Longer calls fall back to the previous stacked layout, so a
  trace mixes inline (small calls) and stacked (big ones). `:width` is
  configurable per trace (`CodeStory.tell(fn -> … end, width: 120)`).
- Ecto queries render compactly in traces. An `Ecto.Query` argument to a boundary
  call now reads as `#Ecto.Query<MyApp.Accounts.User>` (the queried schema) at the
  summary detail levels, instead of the full
  `#Ecto.Query<from r0 in …, where: …, order_by: …>` dump; string-table and
  subquery sources render `#Ecto.Query<"table">` / `#Ecto.Query<subquery>`. The
  full query is preserved at `:novel`. No Ecto dependency — detection is structural.
- Ecto struct noise is stripped from inspected values in the trace — a schema's
  `__meta__: #Ecto.Schema.Metadata<…>` bookkeeping and unloaded associations
  (`#Ecto.Association.NotLoaded<…>`) are removed, so a value reads as
  `%Order{id: 12, status: "paid", …}` instead of the full Ecto internals. The
  `%Mod{…}` struct name is preserved, and it works with no Ecto dependency —
  detection is purely string-shaped.

## [0.1.0]

Initial release.

### Added

- `CodeStory.tell/1` and `CodeStory.tell/2` in block form — wrap a call
  (`CodeStory.tell(fn -> process_order(params) end)`) to print its trace and get
  the wrapped call's own result back. Tracing is cleaned up automatically, so no
  `stop/0` is needed, and the wrapper never breaks the code it wraps: if tracing
  cannot start or the trace cannot be displayed, the function still runs and
  still returns its result.
- `CodeStory.tell/0`, `CodeStory.tell/1`, and `CodeStory.stop/0` in manual form —
  bracket a region by hand when a single entry call will not express it, printing
  a nested call tree of user-defined function calls with named arguments and
  return values.
- `CodeStory.narrate/2` — run a function while tracing and get back
  `{result, tree}` as data, without printing.
- `CodeStory.to_encodable/2` — convert a call tree into a JSON-ready,
  dependency-free plain-data structure.
- `:detail` option with three levels — `:outline`, `:short_story` (default), and
  `:novel` — controlling how much of each value is shown.
- `:fold_repeats` (default `true`) — collapses consecutive sibling calls to the
  same function into a single `×N` node.
- `:auto_boundary` (default `true`) — treats Ecto repos as boundary modules,
  hiding their internal plumbing while keeping the call itself visible.
- `:depth` — caps how many levels the rendered trace nests.
- `:output` — write the trace to `:terminal` (default), `:file`, or `:both`.
- `:show_args` — show argument names alongside values (default `true`).

[Unreleased]: https://github.com/angeleah/code_story/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/angeleah/code_story/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/angeleah/code_story/releases/tag/v0.1.0
