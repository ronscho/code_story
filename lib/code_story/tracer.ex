defmodule CodeStory.Tracer do
  @moduledoc """
  Configures Erlang tracing to feed events into the Collector.

  Uses the `:trace` module with session-based tracing, introduced in OTP 27.0.
  The Collector pid is set as the tracer — trace messages arrive
  directly as `handle_info` callbacks.
  """

  @doc """
  Starts tracing the given process for calls to the given modules.

  The `collector_pid` receives trace messages directly.
  Returns `:ok` or `{:error, reason}`.
  """
  def start_tracing(collector_pid, modules, traced_pid, follow \\ [], timing \\ false) do
    try do
      # Use a unique session name to avoid conflicts
      session_name = :"code_story_trace_#{:erlang.unique_integer([:positive])}"
      session = :trace.session_create(session_name, collector_pid, [])

      # `:set_on_spawn` hands the flags to every process the traced one starts,
      # so following the recursion needs no code of ours -- the runtime does it.
      # `:procs` adds the spawn and exit events: spawn says where a child's tree
      # belongs, exit says when it can no longer grow.
      # `:timestamp` makes the runtime stamp every trace message. That is work
      # per call, so it is only asked for when durations are wanted.
      flags = [:call, :set_on_spawn, :procs] ++ if timing, do: [:timestamp], else: []

      :trace.process(session, traced_pid, true, flags)

      # Processes that were already running when the trace started. They have no
      # spawn to inherit flags from, so each is attached by hand.
      #
      # ⚠ `:trace.process/4` rejects a registered name -- "invalid process spec",
      # unlike the legacy `:erlang.trace/3`. Resolving it here also lets a name
      # nobody registered be reported instead of quietly doing nothing.
      Enum.each(follow, fn target ->
        case resolve(target) do
          nil ->
            IO.warn("CodeStory: follow: no process registered as #{inspect(target)}")

          pid ->
            :trace.process(session, pid, true, flags)
        end
      end)

      match_spec = [{:_, [], [{:return_trace}]}]

      # One pattern per module, not one per function. `{Module, :_, :_}` covers
      # every function including private ones, which is what `module_info` was
      # being read for.
      #
      # ⚠ It also covers the compiler-generated `-caller/arity-fun-0-` entries
      # that the per-function loop skipped, because a wildcard cannot skip
      # anything. They are filtered where the events arrive instead; the
      # observable trace is unchanged, and `generated_functions_test.exs` holds
      # that down.
      Enum.each(modules, fn module ->
        :trace.function(session, {module, :_, :_}, match_spec, [:local])
      end)

      # Store session for cleanup
      Process.put(:code_story_trace_session, session)
      :ok
    rescue
      e in ArgumentError ->
        {:error, "Failed to start tracing: #{Exception.message(e)}"}
    end
  end

  # A zero-arity function, for a process that carries no name at all: compute
  # the pid however you have to and hand it back.
  defp resolve(fun) when is_function(fun, 0), do: resolve(fun.())

  defp resolve(target) do
    # `GenServer.whereis/1` knows every name form OTP has -- a pid, a registered
    # atom, `{:global, term}`, `{:via, module, term}`, `{name, node}` -- and
    # answers `nil` for anything it cannot find. Re-deriving that by hand only
    # produces a worse copy that misses `:via`, which is the form a Registry
    # hands out and therefore the one most likely to be passed here.
    case GenServer.whereis(target) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      # A registered name on another node. Tracing does not reach across one.
      _ -> nil
    end
  rescue
    # `whereis` runs the `:via` module's own lookup, which is somebody else's
    # code and may raise on a malformed term. A bad target should be reported,
    # not crash the trace before it starts.
    _ -> nil
  end

  @doc """
  Stops tracing and cleans up. Idempotent — safe to call multiple times.
  """
  def stop_tracing do
    case Process.get(:code_story_trace_session) do
      nil ->
        :ok

      session ->
        try do
          :trace.session_destroy(session)
        rescue
          ArgumentError -> :ok
        end

        Process.delete(:code_story_trace_session)
        :ok
    end
  end
end
