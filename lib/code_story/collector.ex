defmodule CodeStory.Collector do
  @moduledoc """
  GenServer that receives trace events and builds a nested call tree.

  Started with `GenServer.start/2` (not `start_link`) so that a crash
  does not kill the user's calling process.
  """

  use GenServer

  defstruct [
    :caller_pid,
    :args_map,
    :opts,
    :status,
    tree: [],
    stack: [],
    boundaries: [],
    saw_call: false,
    # Microseconds from the most recent timestamped event, or nil when timing is
    # off. Read by the call/return handlers, which are otherwise unaware of it.
    now: nil,
    # One independent build per process. The caller's own entry lives here too,
    # so there is no special case for it.
    pids: %{},
    # child_pid => {parent_pid, anchor} -- where the child's tree belongs.
    spawns: %{},
    live: MapSet.new()
  ]

  ## Public API

  def start(caller_pid, args_map, opts) do
    GenServer.start(__MODULE__, {caller_pid, args_map, opts})
  end

  ## Callbacks

  @impl true
  def init({caller_pid, args_map, opts}) do
    Process.monitor(caller_pid)

    {:ok,
     %__MODULE__{
       caller_pid: caller_pid,
       args_map: args_map,
       opts: opts,
       status: :tracing,
       tree: [],
       stack: [],
       boundaries: Keyword.get(opts, :boundaries, [])
     }}
  end

  @impl true
  def handle_cast({:trace_event, {:call, {mod, fun, args}}}, state) do
    # Sticky: a call event has now been observed. Lets `narrate` distinguish a
    # genuinely call-free run (never true) from a large trace still draining
    # (true, tree not yet complete) — the two are otherwise the same `:tracing`
    # state with an empty `tree`.
    state = %{state | saw_call: true}

    cond do
      dunder?(fun) ->
        {:noreply, %{state | stack: [:skip_dunder | state.stack]}}

      # Boundary module: suppress its OWN interior calls (a call to a boundary
      # module while that same boundary module is already an ancestor). The
      # entry call — no boundary ancestor yet — falls through and is shown.
      mod in state.boundaries and boundary_ancestor?(state.stack, mod) ->
        {:noreply, %{state | stack: [:skip_boundary | state.stack]}}

      true ->
        named_args = enrich_args(mod, fun, args, state.args_map)

        node = %{
          module: mod,
          function: fun,
          args: named_args,
          return: nil,
          children: [],
          # Start time, kept only while the node is on the stack; the return
          # turns it into a duration and drops it.
          started_at: state.now,
          # Identity that survives the node being copied from the stack into a
          # tree. A spawn records the ref of whatever was open at the time, and
          # the merge finds it again afterwards. Internal only -- `Encoder`
          # builds its output map field by field and never passes this on.
          ref: make_ref()
        }

        # Tag a boundary *entry* call (the interior-suppress branch ran first, so
        # only the outermost boundary call reaches here). The formatter renders a
        # tagged node as an inline call signature instead of positional `arg1`s.
        node = if mod in state.boundaries, do: Map.put(node, :boundary, true), else: node

        {:noreply, %{state | stack: [node | state.stack]}}
    end
  end

  def handle_cast({:trace_event, {:return_from, {_mod, _fun, _arity}, return_value}}, state) do
    case state.stack do
      [] ->
        {:noreply, state}

      # Both sentinels (`:skip_dunder`, `:skip_boundary`) are discarded the same
      # way. The `is_atom` guard keeps the following `[current | rest]` clause
      # provably map-only, so it can't bind a sentinel and crash on `%{current | ...}`.
      [sentinel | rest] when is_atom(sentinel) ->
        {:noreply, %{state | stack: rest}}

      [current | rest] ->
        completed =
          case {current.started_at, state.now} do
            {nil, _} ->
              Map.delete(%{current | return: return_value}, :started_at)

            {_, nil} ->
              Map.delete(%{current | return: return_value}, :started_at)

            {t0, t1} ->
              %{current | return: return_value}
              |> Map.delete(:started_at)
              |> Map.put(:duration, max(t1 - t0, 0))
          end

        # Attach to the nearest REAL ancestor, skipping any sentinels
        # (`:skip_dunder` / `:skip_boundary` are atoms, not maps). The skipped
        # sentinels stay on the stack above the updated parent — they haven't
        # returned yet. A real node with no real ancestor is a root.
        case Enum.split_while(rest, &(not is_map(&1))) do
          # A root has closed, so there is a complete tree to hand out -- and
          # there may be more to come. `status` says "complete as of now"; it no
          # longer says "stop listening". A traced region may hold several
          # top-level calls, and one of them returning is not the end of it.
          {_sentinels, []} ->
            new_tree = state.tree ++ [completed]
            {:noreply, %{state | tree: new_tree, stack: [], status: {:completed, new_tree}}}

          {sentinels, [parent | grandparents]} ->
            parent = %{parent | children: parent.children ++ [completed]}
            {:noreply, %{state | stack: sentinels ++ [parent | grandparents]}}
        end
    end
  end

  @impl true
  def handle_call(:get_result, _from, state) do
    case state.status do
      {:completed, tree} ->
        {:reply, {:completed, tree, state.opts}, state}

      :tracing ->
        {:reply, {:tracing, state.tree, state.opts}, state}
    end
  end

  # Completion-aware progress. `tree` carries every root closed so far, and
  # `{:completed, tree}` means "complete as of now" rather than "finished";
  # `saw_call` tells a caller whether any call has arrived yet at all.
  #
  # NOTE: the library itself no longer polls this — `collect/1` stops tracing and
  # asks for `:finish`, which is exact rather than timed. Kept as part of the
  # collector's API.
  # The end of the story, set by whoever opened it. Everything already closed is
  # in `tree`; anything still on the stack is a call that never returned -- a
  # `throw`, a `raise`, or a region ended mid-call -- and is kept rather than
  # dropped, because a call that did not come back is usually the interesting
  # one.
  # How many spawned processes have not been seen to exit yet. A process's own
  # exit event is ordered behind its own call events, so once this reaches zero
  # every child has delivered everything it will ever deliver.
  def handle_call(:pending, _from, state) do
    {:reply, MapSet.size(state.live), state}
  end

  def handle_call(:finish, _from, state) do
    tree = merged_tree(state)

    {:reply, tree, %{state | tree: tree, stack: [], status: {:completed, tree}}}
  end

  def handle_call(:trace_progress, _from, state) do
    reply =
      case state.status do
        {:completed, tree} -> {:completed, tree}
        :tracing -> {:tracing, state.saw_call}
      end

    {:reply, reply, state}
  end

  # Raw trace messages from :trace session (OTP 28+)
  # The Collector pid is set as the tracer, so messages arrive here directly
  @impl true
  # `:timestamp` turns every trace message into its `_ts` variant with the time
  # appended. Mapping them onto the plain clauses keeps one code path for the
  # tree and confines timing to the two places that need it.
  def handle_info({:trace_ts, pid, :call, mfa, ts}, state) do
    handle_info({:trace, pid, :call, mfa}, %{state | now: us(ts)})
  end

  def handle_info({:trace_ts, pid, :return_from, mfa, value, ts}, state) do
    handle_info({:trace, pid, :return_from, mfa, value}, %{state | now: us(ts)})
  end

  def handle_info({:trace_ts, parent, :spawn, child, mfa, _ts}, state) do
    handle_info({:trace, parent, :spawn, child, mfa}, state)
  end

  def handle_info({:trace_ts, pid, :exit, reason, _ts}, state) do
    handle_info({:trace, pid, :exit, reason}, state)
  end

  def handle_info({:trace, pid, :call, {mod, fun, args}}, state) do
    state = anchor_unknown(pid, state)

    for_pid(pid, state, &handle_cast({:trace_event, {:call, {mod, fun, args}}}, &1))
  end

  # Where a child's tree belongs, decided at the moment it is created.
  #
  # If the parent has a call open, the child's work happened inside it and hangs
  # underneath. If it does not -- which is the common case, because the spawn
  # usually happens in library code this tracer does not follow -- there is no
  # node to hang it on, and the honest placement is the parent's own sequence,
  # at the point in time the spawn occurred.
  def handle_info({:trace, parent, :spawn, child, _mfa}, state) do
    {tree, stack} = Map.get(state.pids, parent, {[], []})

    anchor =
      case Enum.find(stack, &is_map/1) do
        nil -> {:root_at, length(tree)}
        node -> {:under, node.ref}
      end

    # `Map.put`, deliberately overwriting. A child's first call can reach the
    # collector before its parent's spawn event -- they come from two different
    # processes, so nothing orders them against each other -- and `anchor_unknown`
    # will have guessed an anchor by then. This is the precise one: it names the
    # real parent and the node that was open in it at the moment of the spawn.
    # The guess loses, which is the outcome wanted.
    {:noreply,
     %{
       state
       | spawns: Map.put(state.spawns, child, {parent, anchor}),
         live: MapSet.put(state.live, child)
     }}
  end

  def handle_info({:trace, pid, :exit, _reason}, state) do
    {:noreply, %{state | live: MapSet.delete(state.live, pid)}}
  end

  def handle_info({:trace, pid, :return_from, {mod, fun, arity}, return_value}, state) do
    for_pid(
      pid,
      state,
      &handle_cast({:trace_event, {:return_from, {mod, fun, arity}, return_value}}, &1)
    )
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{caller_pid: pid} = state) do
    {:stop, :normal, state}
  end

  # Everything else the `:procs` flag produces -- `:spawned`, `:link`,
  # `:getting_unlinked` and friends -- is not part of a call tree.
  #
  # ⚠ Both shapes need both forms. With `timing: true` every message arrives as
  # its `:trace_ts` variant with the time appended, so a 4-tuple becomes a
  # 5-tuple and a 5-tuple a 6-tuple. Omitting the `_ts` catch-alls crashes the
  # collector on the first spawn of a timed trace -- which each feature's own
  # tests missed, because the timing tests spawned nothing and the spawn tests
  # measured nothing.
  def handle_info({:trace, _pid, _type, _info}, state), do: {:noreply, state}
  def handle_info({:trace, _pid, _type, _info, _extra}, state), do: {:noreply, state}
  def handle_info({:trace_ts, _pid, _type, _info, _ts}, state), do: {:noreply, state}

  def handle_info({:trace_ts, _pid, _type, _info, _extra, _ts}, state),
    do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  ## Private

  defp enrich_args(mod, fun, args, args_map) do
    arity = length(args)

    names =
      case Map.fetch(args_map, {mod, fun, arity}) do
        {:ok, names} -> names
        :error -> Enum.map(1..max(arity, 1)//1, &:"arg#{&1}") |> Enum.take(arity)
      end

    Enum.zip(names, args)
  end

  # Folds the per-process trees back into one, children first.
  #
  # A child is merged into its parent only once the child has absorbed its own
  # children, so a chain of spawns comes out nested rather than flat. The order
  # falls out of the data: repeatedly merge every process that nobody still
  # names as a parent.
  defp merged_tree(state) do
    trees = Map.new(state.pids, fn {pid, pair} -> {pid, flush(pair)} end)
    trees = fold_children(trees, state.spawns)

    trees
    |> Map.get(state.caller_pid, [])
    |> strip_refs()
  end

  # `:ref` is bookkeeping for the merge and stops at this boundary. A node is
  # `%{module, function, args, return, children}` to everyone outside, which is
  # what `narrate/2` documents and what callers pattern-match on.
  defp strip_refs(tree) do
    Enum.map(tree, fn node ->
      node
      |> Map.delete(:ref)
      |> Map.update!(:children, &strip_refs/1)
    end)
  end

  # Anything still on the stack never returned -- a throw, a raise, a region
  # ended mid-call. Kept: a call that did not come back is usually the one worth
  # seeing.
  defp flush({tree, stack}) do
    offen = stack |> Enum.filter(&is_map/1) |> Enum.map(&Map.delete(&1, :started_at))

    tree ++ Enum.reverse(offen)
  end

  defp fold_children(trees, spawns) when map_size(spawns) == 0, do: trees

  defp fold_children(trees, spawns) do
    parents = MapSet.new(spawns, fn {_child, {parent, _anchor}} -> parent end)

    case Enum.reject(Map.keys(spawns), &MapSet.member?(parents, &1)) do
      # Every remaining child is also somebody's parent: a spawn cycle, which
      # cannot happen, or a parent whose own parent we never saw. Stop rather
      # than loop.
      [] ->
        trees

      leaves ->
        {trees, spawns} =
          Enum.reduce(leaves, {trees, spawns}, fn child, {trees, spawns} ->
            {{parent, anchor}, spawns} = Map.pop(spawns, child)
            {child_tree, trees} = Map.pop(trees, child, [])

            {Map.put(trees, parent, attach(Map.get(trees, parent, []), anchor, child_tree)),
             spawns}
          end)

        fold_children(trees, spawns)
    end
  end

  defp attach(tree, _anchor, []), do: tree

  defp attach(tree, {:under, ref}, child_tree) do
    Enum.map(tree, fn
      %{ref: ^ref} = node -> %{node | children: node.children ++ child_tree}
      node -> %{node | children: attach(node.children, {:under, ref}, child_tree)}
    end)
  end

  defp attach(tree, {:root_at, index}, child_tree) do
    {before, rest} = Enum.split(tree, index)
    before ++ child_tree ++ rest
  end

  # A process heard from for the first time that nobody spawned -- one named in
  # `follow:`, already running before the trace began. It has no spawn event, so
  # its anchor is taken now, from where the caller stands at the moment its first
  # call arrives. For a synchronous `GenServer.call` that is exactly right: the
  # caller is blocked inside the call, so the node open above it is the one that
  # asked for this work.
  #
  # ⚠ It is also a provisional answer for a spawned process whose spawn event has
  # not arrived yet -- the two messages come from different processes and nothing
  # orders them. That case corrects itself: the spawn handler overwrites this with
  # the real parent and the node open in it at the time.
  defp anchor_unknown(pid, state) do
    if pid == state.caller_pid or Map.has_key?(state.spawns, pid) do
      state
    else
      {tree, stack} = Map.get(state.pids, state.caller_pid, {[], []})

      anchor =
        case Enum.find(stack, &is_map/1) do
          nil -> {:root_at, length(tree)}
          node -> {:under, node.ref}
        end

      %{state | spawns: Map.put(state.spawns, pid, {state.caller_pid, anchor})}
    end
  end

  # Swaps one process's tree and stack in, runs the existing single-process
  # logic on them, and puts the result back. Events from different processes
  # arrive interleaved in one mailbox; this is what keeps them apart.
  defp for_pid(pid, state, fun) do
    {tree, stack} = Map.get(state.pids, pid, {[], []})
    {:noreply, next} = fun.(%{state | tree: tree, stack: stack})

    {:noreply, %{next | pids: Map.put(next.pids, pid, {next.tree, next.stack})}}
  end

  defp us({mega, sec, micro}), do: (mega * 1_000_000 + sec) * 1_000_000 + micro

  defp dunder?(fun) do
    name = Atom.to_string(fun)
    String.starts_with?(name, "__") and String.ends_with?(name, "__")
  end

  # True if a real node for `mod` is already on the stack (an ancestor of the
  # call being considered). Runs before the new node is pushed, so it scans
  # ancestors only — `is_map/1` skips sentinel atoms.
  @spec boundary_ancestor?([map() | atom()], module()) :: boolean()
  defp boundary_ancestor?(stack, mod) do
    Enum.any?(stack, &(is_map(&1) and &1.module == mod))
  end
end
