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
  def start_tracing(
        collector_pid,
        modules,
        traced_pid,
        follow \\ [],
        timing \\ false,
        values \\ true
      ) do
    try do
      # ⚠⚠ Two sessions, not one, and that is the whole feature. Trace flags are
      # set per PROCESS, not per function -- so arming some modules cheaply and
      # others fully is impossible within one session. Sessions (OTP 27) exist
      # for exactly this: each carries its own flags for the same process, and a
      # function obeys the session it was armed in. Verified before relying on
      # it: one process, one collector, two sessions, and the same call comes
      # back as `{M, F, 1}` from one and `{M, F, [5, "speed"]}` from the other.
      #
      # ⓘ Which is what makes `values:` a *choice* rather than a switch. The
      # expensive arguments are rarely the interesting ones -- a framework
      # struct threaded through every layer carries the sharing that makes
      # copying explode, while the call worth reading takes an id and a name.
      {mit_werten, ohne_werte} = teile(modules, values)

      flags = [:call, :set_on_spawn, :procs] ++ if timing, do: [:timestamp], else: []
      match_spec = [{:_, [], [{:return_trace}]}]

      sessions =
        [{mit_werten, flags}, {ohne_werte, flags ++ [:arity]}]
        |> Enum.reject(fn {module, _} -> module == [] end)
        |> Enum.map(fn {module, session_flags} ->
          session =
            :trace.session_create(
              :"code_story_trace_#{:erlang.unique_integer([:positive])}",
              collector_pid,
              []
            )

          :trace.process(session, traced_pid, true, session_flags)

          # Processes that were already running when the trace started. They
          # have no spawn to inherit flags from, so each is attached by hand.
          #
          # ⚠ `:trace.process/4` rejects a registered name -- "invalid process
          # spec", unlike the legacy `:erlang.trace/3`. Resolving it here also
          # lets a name nobody registered be reported instead of quietly doing
          # nothing.
          Enum.each(follow, fn target ->
            case resolve(target) do
              nil ->
                IO.warn("CodeStory: follow: no process registered as #{inspect(target)}")

              pid ->
                :trace.process(session, pid, true, session_flags)
            end
          end)

          # One pattern per module, not one per function. `{Module, :_, :_}`
          # covers every function including private ones, which is what
          # `module_info` was being read for.
          #
          # ⚠ It also covers the compiler-generated `-caller/arity-fun-0-`
          # entries that the per-function loop skipped, because a wildcard
          # cannot skip anything. They are filtered where the events arrive
          # instead; the observable trace is unchanged, and
          # `generated_functions_test.exs` holds that down.
          Enum.each(module, fn m ->
            :trace.function(session, {m, :_, :_}, match_spec, [:local])
          end)

          session
        end)

      # Store sessions for cleanup
      Process.put(:code_story_trace_session, sessions)
      :ok
    rescue
      e in ArgumentError ->
        {:error, "Failed to start tracing: #{Exception.message(e)}"}
    end
  end

  # `values: true` -- everything as before. `false` -- nothing, the whole trace
  # armed with `:arity`. A **list** -- these modules carry their values and the
  # rest do not, which is the form worth reaching for on a real request.
  defp teile(modules, true), do: {modules, []}
  defp teile(modules, false), do: {[], modules}

  defp teile(modules, gewaehlt) when is_list(gewaehlt) do
    gewaehlt = MapSet.new(gewaehlt)
    Enum.split_with(modules, &MapSet.member?(gewaehlt, &1))
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

      sessions ->
        Enum.each(List.wrap(sessions), fn session ->
          try do
            :trace.session_destroy(session)
          rescue
            ArgumentError -> :ok
          end
        end)

        Process.delete(:code_story_trace_session)
        :ok
    end
  end
end
