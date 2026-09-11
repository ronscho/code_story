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
    saw_call: false
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
          children: []
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
        completed = %{current | return: return_value}

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
  def handle_call(:finish, _from, state) do
    tree = state.tree ++ Enum.reverse(Enum.filter(state.stack, &is_map/1))

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
  def handle_info({:trace, _pid, :call, {mod, fun, args}}, state) do
    handle_cast({:trace_event, {:call, {mod, fun, args}}}, state)
  end

  def handle_info({:trace, _pid, :return_from, {mod, fun, arity}, return_value}, state) do
    handle_cast({:trace_event, {:return_from, {mod, fun, arity}, return_value}}, state)
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{caller_pid: pid} = state) do
    {:stop, :normal, state}
  end

  # Ignore other trace messages (e.g. :trace_ts variants)
  def handle_info({:trace, _pid, _type, _info}, state), do: {:noreply, state}
  def handle_info({:trace, _pid, _type, _info, _extra}, state), do: {:noreply, state}

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
