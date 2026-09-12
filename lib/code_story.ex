defmodule CodeStory do
  @moduledoc """
  A code comprehension tool for surveying unfamiliar Elixir code.

  Drop `CodeStory.tell()` into a function to see a nested call tree of
  user-defined function calls with named arguments, values, and return values.

  ## Usage

  Wrap the call you're curious about — the trace prints and your result flows
  through, no `stop/0` needed:

      invoice = CodeStory.tell(fn -> process_order(params) end)

  Or bracket a region by hand when a single entry call won't express it:

      CodeStory.tell()
      # ... your code ...
      CodeStory.stop()

  For the tree as data instead of a printed trace, see `narrate/2`.

  ## Options

    * `:show_args` - when `true` (default), shows argument names and values;
      when `false`, shows values only
    * `:output` - `:terminal` (default), `:file`, or `:both`. `:file` and
      `:both` write to `code_story_trace.log` in the project root. Because a
      trace records real argument and return values, that file can capture
      secrets (passwords, API keys, tokens) or personal data in plaintext —
      add it to your `.gitignore` and delete it when you are done with it.
    * `:detail` - `:outline` shows only function names and arg names (no values
      or returns) for inspecting call flow and boundaries;
      `:short_story` (default) shows names, truncated values, and returns;
      `:novel` shows names with complete untruncated values and returns
    * `:follow` - processes to trace besides the calling one, named any way OTP
      allows — a pid, a registered atom, `{:global, term}`, `{:via, Registry,
      key}` — or a zero-arity function returning a pid, for a process with no
      name at all: `follow: [MyApp.Cache, some_pid, fn -> lookup() end]`.
      Processes the traced code
      *starts* are followed automatically; this is for the ones that were already
      running — a supervised GenServer, a registry, a channel — which have no
      spawn to inherit from. Their calls appear under the call that reached them,
      which for a synchronous `GenServer.call` is exactly where they belong. A
      target that cannot be reached — including a pid that has already died — is
      reported and the trace runs without it. ⚠ Following attaches to a
      *process*, not to a conversation: everything that process does during the
      window is recorded, including work other callers asked it for.
    * `:extra_namespaces` - further top-level namespaces to trace, for app code
      that does not live under the app-name prefix:
      `extra_namespaces: ["EmailService", "StripeApi"]`. Detection reads
      `mix.exs` and arms `MyApp.*` and `MyAppWeb.*`; a mailer under
      `EmailService`, an API client under its vendor's name, a `Core` extracted
      but not yet its own app are all your code and none of them match. ⚠ The
      symptom is silent: those calls are **missing** from the trace, which reads
      like the code never ran. Additive — the app's own namespaces are always
      armed.
    * `:timing` - when `true`, every node carries `duration` in microseconds.
      Off by default: the `:timestamp` trace flag makes the runtime stamp every
      message, which is work per call, and a trace read for structure should not
      pay for it. ⚠ A duration is **total** — the call and everything beneath it,
      including the tracing overhead of everything beneath it. Good for comparing
      siblings, misleading as a benchmark.
    * `:boundaries` - modules to treat as boundaries, beyond the ones
      `:auto_boundary` finds: `boundaries: [MyApp.Accounts, MyApp.MailClient]`.
      Where a functional core ends and a boundary begins is a design decision,
      not a property a tool can detect — a context, an adapter, a client wrapper
      are all boundaries by intent. Declared and detected ones add up.
    * `:auto_boundary` - when `true` (default), Ecto repos are treated as
      *boundary modules*: a repo call (e.g. `Repo.get!`) is shown as a single
      node with its args and return, but the repo's own internal calls (Ecto
      plumbing, arity-delegation chains) are hidden. Set to `false` to trace
      repo internals.
    * `:fold_repeats` - when `true` (default), consecutive sibling calls to the
      same function collapse into one node marked `×N` (or `×N (varies)` when the
      calls share a function but differ). Set to `false` to show every call.
    * `:depth` - caps how many levels the rendered trace nests. A positive
      integer (`depth: 1` shows the entry call only; `depth: 2` adds its direct
      children; etc.); below the cap a node's interior is replaced by a
      `… (N more levels)` marker. Defaults to `:infinity` (no limit).
    * `:width` - the line-width budget (default `100`) for the compact inline
      call signature `Mod.fun(name: value, …) => return`. A call whose assembled
      line fits within `:width` renders inline; a longer one falls back to the
      stacked layout (name / one arg per line / return). Raise it for a wide
      terminal, lower it for a strict slide.
  """

  @collector_key :code_story_collector

  @doc """
  Traces user-defined function calls and prints the call tree. Two forms.

  ## Block form — `tell(fun)` / `tell(fun, opts)`

  Wrap the entry call you want to understand. The trace prints, tracing is cleaned
  up automatically (no `stop/0`), and `fun`'s own result is returned — so it's a
  transparent wrapper you can drop around any expression:

      invoice = CodeStory.tell(fn -> process_order(params) end)

  This is the recommended form when surveying unfamiliar code: you know the *entry*
  even when you don't know where the flow *ends*. A single entry call is still the
  clearest thing to wrap, but `fun` may hold several: every top-level call becomes
  a root of the trace, in call order. That matters when the entry point is
  framework code the tracer does not follow -- your own functions are then reached
  as a sequence, not as one call. It **never breaks the wrapped
  code** — if a trace is already active, tracing fails to start, or the trace can't
  be displayed, `fun` still runs and its result is still returned (with a warning).
  Unlike `narrate/2` (which raises on an active trace), the block form warns and
  continues.

  ## Manual form — `tell()` / `tell(opts)` + `stop/0`

  Bracket a region by hand (e.g. a LiveView handler, or a span across several
  statements) when a single entry call won't express it:

      CodeStory.tell()
      result = process_order(params)
      CodeStory.stop()

  The manual form returns `:ok`, or `{:error, :already_tracing}` (with a warning)
  if a trace is already active.

  Both forms accept the options in the [module docs](`CodeStory`) — `:show_args`,
  `:output`, `:detail`, `:auto_boundary`, `:fold_repeats`, `:depth`, `:width`:

      CodeStory.tell(fn -> entry() end, detail: :outline)
      CodeStory.tell(detail: :novel, output: :file)

  For the tree as data instead of a printed trace, see `narrate/2`.
  """
  @spec tell() :: :ok | {:error, term()}
  @spec tell(keyword()) :: :ok | {:error, term()}
  @spec tell((-> result)) :: result when result: var
  @spec tell((-> result), keyword()) :: result when result: var
  def tell(), do: do_manual_start([])

  # arity 1 — all three clauses contiguous (Elixir warns on split same-arity clauses)
  def tell(fun) when is_function(fun, 0), do: tell(fun, [])
  def tell(opts) when is_list(opts), do: do_manual_start(opts)

  def tell(other) do
    raise ArgumentError,
          "CodeStory.tell/1 expects a keyword list or a 0-arity function, got: #{inspect(other)}"
  end

  # arity 2
  def tell(fun, opts) when is_function(fun, 0) and is_list(opts), do: do_tell_block(fun, opts)

  def tell(fun, opts) when is_function(fun, 0) do
    raise ArgumentError,
          "CodeStory.tell/2 expects a keyword list as the second argument, got: #{inspect(opts)}"
  end

  def tell(fun, _opts) do
    raise ArgumentError,
          "CodeStory.tell/2 expects a 0-arity function as the first argument, got: #{inspect(fun)}"
  end

  @doc """
  Stops tracing and outputs the call tree collected since `tell/1`.

  The entire trace is written as one buffered block, using the `:output` and
  `:detail` options given to `tell/1` — so the tree never interleaves with other
  IO from your code.

  Always returns `:ok`. Warns and returns `:ok` if no trace is active on this
  process, so a stray `stop/0` is harmless.
  """
  @spec stop() :: :ok
  def stop do
    case Process.get(@collector_key) do
      nil ->
        IO.warn("CodeStory: no active trace")
        :ok

      collector_pid ->
        do_stop(collector_pid)
    end
  end

  @doc """
  Runs `fun` while tracing, returning `{result, tree}` without printing.

  `result` is whatever `fun` returned; `tree` is the raw call tree as data — a
  list of `%{module, function, args, return, children}` node maps. This is the
  programmatic counterpart to `tell/0` + `stop/0`: nothing is written to the
  terminal or a file, and no display transforms (folding, depth) are applied — the
  tree is the honest, full structure. Pair it with `to_encodable/2` to get
  JSON-ready data.

      {invoice, tree} = CodeStory.narrate(fn -> process_order(params) end)

  Notes:

    * Traces the calling process. Every top-level call inside `fun` becomes a root
      of the returned tree, in call order, so `fun` may bracket a region rather
      than wrap a single entry call. A `fun` with no traced calls returns
      `{result, []}`. Processes `fun` spawns are followed; ones that were already
      running are followed when named in `:follow`.
    * `opts` are trace-time only — `:auto_boundary` (default `true`, as in
      `tell/1`), `:follow` and `:extra_namespaces`. Pass `auto_boundary: false`
      to include an Ecto repo's internals in the raw tree; pass `follow:` to
      trace processes that were already running; pass `extra_namespaces:` to
      trace app code living outside the app-name prefix.
    * **Raises** `ArgumentError` if a trace is already active on this process
      (unlike `tell/1`, which returns `{:error, :already_tracing}` — a tagged tuple
      would be ambiguous with a legitimate `{:error, tree}` result).
  """
  @spec narrate((-> result), keyword()) :: {result, [map()]} when result: var
  def narrate(fun, opts \\ []) when is_function(fun, 0) do
    if Process.get(@collector_key) do
      raise ArgumentError, "CodeStory.narrate: a trace is already active on this process"
    end

    opts = Keyword.merge([auto_boundary: true], opts)

    case do_start(opts) do
      :ok ->
        # do_start put the collector pid under @collector_key before returning :ok.
        collector_pid = Process.get(@collector_key)

        try do
          result = fun.()
          {result, collect(collector_pid)}
        after
          CodeStory.Tracer.stop_tracing()
          Process.delete(@collector_key)
          # Benign TOCTOU: the collector only dies if its monitored caller (this
          # process) dies, which cannot happen mid-cleanup here.
          if is_pid(collector_pid) and Process.alive?(collector_pid) do
            GenServer.stop(collector_pid)
          end
        end

      {:error, reason} ->
        raise "CodeStory.narrate: could not start tracing (#{inspect(reason)})"
    end
  end

  @doc """
  Converts a call tree (from `narrate/2`) into a JSON-ready plain-data structure.

  Dependency-free: the result contains only strings / numbers / booleans / nil /
  lists / maps, so `JSON.encode!/1` (Elixir 1.18+) or `Jason.encode!/1` works
  directly. Faithful by default; opt into compaction with `:fold_repeats`,
  `:depth`, and `:detail`. See `CodeStory.Encoder` for the schema and options.

      {_result, tree} = CodeStory.narrate(fn -> entry() end)
      data = CodeStory.to_encodable(tree, fold_repeats: true, depth: 4)
  """
  @spec to_encodable([map()], keyword()) :: [map()]
  def to_encodable(tree, opts \\ []), do: CodeStory.Encoder.encode(tree, opts)

  defp do_manual_start(opts) do
    if Process.get(@collector_key) do
      IO.warn("CodeStory: trace already active on this process")
      {:error, :already_tracing}
    else
      do_start(merge_display_defaults(opts))
    end
  end

  defp merge_display_defaults(opts) do
    Keyword.merge(
      [
        show_args: true,
        output: :terminal,
        detail: :short_story,
        auto_boundary: true,
        fold_repeats: true,
        depth: :infinity,
        width: 100
      ],
      opts
    )
  end

  # Block form: wrap `fun`, print its trace, clean up, return `fun`'s own result.
  # Contract: NEVER break the wrapped code — an already-active trace, a start
  # failure, or a display/write error must all still run `fun` and return its value.
  defp do_tell_block(fun, opts) do
    if Process.get(@collector_key) do
      # A pre-existing trace's tracing is still on this process AND its collector
      # may already have auto-frozen, so fun runs but may or may not be captured.
      IO.warn(
        "CodeStory: an existing trace is active on this process; " <>
          "your function runs normally and may not be captured"
      )

      fun.()
    else
      opts = merge_display_defaults(opts)

      case safe_start(opts) do
        :ok ->
          collector_pid = Process.get(@collector_key)

          try do
            result = fun.()

            # Collect + render is best-effort: collect/1 can :exit on a wedged
            # collector, output_result can raise (File.write! / formatter). Neither
            # may clobber a successful fun, so both are guarded (rescue AND catch).
            try do
              collector_pid |> collect() |> output_result(opts)
            rescue
              e ->
                IO.warn(
                  "CodeStory: trace collected but could not be displayed (#{Exception.message(e)})"
                )
            catch
              :exit, reason ->
                IO.warn("CodeStory: trace could not be collected (#{inspect(reason)})")

              :throw, value ->
                IO.warn("CodeStory: trace could not be collected (#{inspect(value)})")
            end

            result
          after
            CodeStory.Tracer.stop_tracing()
            Process.delete(@collector_key)

            if is_pid(collector_pid) and Process.alive?(collector_pid) do
              GenServer.stop(collector_pid)
            end
          end

        {:could_not_start, reason} ->
          IO.warn(
            "CodeStory: could not start tracing (#{inspect(reason)}); running your function untraced"
          )

          fun.()
      end
    end
  end

  @doc false
  # Totalizes `do_start/1`: any non-:ok result, raise, exit, or throw becomes
  # `{:could_not_start, reason}`. `start_fun` is injectable (default `&do_start/1`)
  # so start-failure paths are testable without a mocking dependency. Uses a
  # SEQUENCED block (not `cleanup && …`) — cleanup returns `nil` on a failed start,
  # which `&&` would short-circuit into a CaseClauseError that breaks wrapped code.
  @spec safe_start(keyword(), (keyword() -> :ok | {:error, term()})) ::
          :ok | {:could_not_start, term()}
  def safe_start(opts, start_fun \\ &do_start/1) do
    case start_fun.(opts) do
      :ok ->
        :ok

      other ->
        cleanup_after_failed_start()
        {:could_not_start, other}
    end
  rescue
    e ->
      cleanup_after_failed_start()
      {:could_not_start, e}
  catch
    :exit, reason ->
      cleanup_after_failed_start()
      {:could_not_start, reason}

    :throw, value ->
      cleanup_after_failed_start()
      {:could_not_start, value}
  end

  # Best-effort teardown of any partial state a failed start may have left.
  # Self-totalizing: it runs inside `safe_start`'s rescue/catch arms (which are not
  # themselves guarded), so a raise/exit here — e.g. a `GenServer.stop/1` :noproc
  # TOCTOU — must not escape and break the wrapped code. Swallow everything.
  defp cleanup_after_failed_start do
    CodeStory.Tracer.stop_tracing()

    case Process.get(@collector_key) do
      pid when is_pid(pid) ->
        Process.delete(@collector_key)
        if Process.alive?(pid), do: GenServer.stop(pid)

      _ ->
        :ok
    end
  catch
    _kind, _reason -> :ok
  end

  defp do_start(opts) do
    # Namespaces beyond the app-name prefix, for app code that does not live
    # under it. Nothing is subtracted -- `MyApp.*` and `MyAppWeb.*` are always
    # in.
    modules = CodeStory.Modules.detect(Keyword.get(opts, :extra_namespaces, []))
    args_map = CodeStory.Args.extract(modules)

    # `tell/1` merges the `auto_boundary: true` default, so the value is always
    # present here — the default lives in exactly one place (the merge above).
    # Declared boundaries and detected ones add up. `auto_boundary` decides
    # whether repos are found for you; `boundaries:` is where you say which of
    # your own modules marks the edge of your core -- a decision the tool cannot
    # sniff out, because it is a design decision and not a library property.
    detected =
      if Keyword.get(opts, :auto_boundary) do
        CodeStory.Modules.ecto_repos(modules)
      else
        []
      end

    declared = Keyword.get(opts, :boundaries, [])

    opts = Keyword.put(opts, :boundaries, Enum.uniq(declared ++ detected))

    {:ok, collector_pid} = CodeStory.Collector.start(self(), args_map, opts)

    follow = Keyword.get(opts, :follow, [])

    timing = Keyword.get(opts, :timing, false)

    case CodeStory.Tracer.start_tracing(collector_pid, modules, self(), follow, timing) do
      :ok ->
        Process.put(@collector_key, collector_pid)
        :ok

      {:error, reason} ->
        GenServer.stop(collector_pid)
        {:error, reason}
    end
  end

  defp do_stop(collector_pid) do
    result =
      try do
        GenServer.call(collector_pid, :get_result)
      catch
        :exit, {:noproc, _} ->
          IO.warn("CodeStory: trace collector crashed — no output available")
          nil
      end

    CodeStory.Tracer.stop_tracing()
    Process.delete(@collector_key)

    case result do
      {:completed, tree, opts} ->
        output_result(tree, opts)

      {:tracing, _tree, opts} ->
        # Still tracing — get whatever tree we have
        tree =
          try do
            case GenServer.call(collector_pid, :get_result) do
              {:completed, tree, _} -> tree
              {:tracing, tree, _} -> tree
            end
          catch
            :exit, _ -> []
          end

        output_result(tree, opts)

      nil ->
        :ok
    end

    if Process.alive?(collector_pid), do: GenServer.stop(collector_pid)
    :ok
  end

  # Trace events reach the collector asynchronously, and the collector only fills
  # `tree` at completion (nodes live on its stack until then) — so there is no
  # observable "partial tree", only `:tracing` vs `:completed`. Poll `:completed`.
  #
  # Stop tracing first, then ask for the tree. The order is the barrier: trace
  # messages for this process are delivered in order relative to our own
  # `GenServer.call`, so once no further events can be generated, everything
  # generated is already in the collector's mailbox ahead of the call.
  #
  # ⚠ That guarantee covers the traced process only. It does not extend to
  # processes it spawned, which is why following spawned processes needs a
  # different barrier than this one.
  # Wait for spawned processes, THEN stop tracing, THEN ask for the tree.
  #
  # The order is the barrier, and each step earns its place. Messages from a
  # child are not ordered against our own `GenServer.call`, so the single-process
  # argument does not carry here -- but a process's exit event *is* ordered
  # behind its own calls, so a child that has been seen to exit has delivered
  # everything. Waiting has to happen while tracing is still on, since stopping
  # it is what ends the events we are waiting for.
  #
  # A child that outlives the region never exits, so the wait is bounded: its
  # calls up to that point are kept, and the trace is produced rather than
  # withheld.
  @drain_ceiling_ms 200

  defp collect(pid) do
    drain(pid, 0)
    CodeStory.Tracer.stop_tracing()

    try do
      GenServer.call(pid, :finish)
    catch
      :exit, {:noproc, _} -> []
    end
  end

  defp drain(pid, waited) do
    case GenServer.call(pid, :pending) do
      0 ->
        :ok

      _ when waited >= @drain_ceiling_ms ->
        :ok

      _ ->
        Process.sleep(2)
        drain(pid, waited + 2)
    end
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
  end

  defp output_result(tree, _opts) when tree == [], do: :ok

  defp output_result(tree, opts) do
    tree = if Keyword.get(opts, :fold_repeats, true), do: CodeStory.Fold.fold(tree), else: tree
    output_mode = Keyword.get(opts, :output, :terminal)

    case output_mode do
      :terminal ->
        IO.puts(CodeStory.Formatter.format(tree, opts))

      :file ->
        write_file(tree, opts)

      :both ->
        IO.puts(CodeStory.Formatter.format(tree, opts))
        write_file(tree, opts)
    end
  end

  defp write_file(tree, opts) do
    content = CodeStory.Formatter.format_plain(tree, opts)
    path = Path.join(File.cwd!(), "code_story_trace.log")
    File.write!(path, content)
  end
end
