defmodule CodeStory.FollowTest do
  @moduledoc """
  `follow:` traces processes that already exist.

  Spawn-following covers what the traced code starts. It does nothing for a
  process that was already running — a supervised GenServer, a registry, a
  channel — because there is no spawn to inherit from. Those are usually the
  ones you want to understand: a `GenServer.call` shows the caller blocking and
  nothing of the work it asked for.

  ⚠ `:trace.process/4` does not accept a registered name — "invalid process
  spec", unlike the legacy `:erlang.trace/3`. Names are resolved here instead,
  which also makes the failure honest: a name nobody registered is reported
  rather than silently ignored.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule Counter do
    @moduledoc false
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, 0, name: name)

    @impl GenServer
    def init(n), do: {:ok, n}

    @impl GenServer
    def handle_call({:bump, by}, _from, n), do: {:reply, step(n, by), n + by}

    defp step(n, by), do: n + by
  end

  setup do
    on_exit(fn ->
      CodeStory.Tracer.stop_tracing()

      case Process.get(:code_story_collector) do
        nil -> :ok
        pid -> if Process.alive?(pid), do: GenServer.stop(pid)
      end

      Process.delete(:code_story_collector)
    end)

    :ok
  end

  describe "a process that was already running" do
    test "is invisible without follow:" do
      {:ok, srv} = Counter.start_link(:counter_plain)

      {result, tree} = CodeStory.narrate(fn -> GenServer.call(:counter_plain, {:bump, 2}) end)

      assert result == 2
      assert functions(tree) == []

      GenServer.stop(srv)
    end

    test "is traced when named in follow:" do
      {:ok, srv} = Counter.start_link(:counter_named)

      {result, tree} =
        CodeStory.narrate(fn -> GenServer.call(:counter_named, {:bump, 2}) end,
          follow: [:counter_named]
        )

      assert result == 2
      names = functions(tree)
      assert "handle_call" in names
      # Private helpers inside the followed process are traced like any other.
      assert "step" in names

      GenServer.stop(srv)
    end

    test "accepts a pid as well as a name" do
      {:ok, srv} = Counter.start_link(:counter_by_pid)

      {_result, tree} =
        CodeStory.narrate(fn -> GenServer.call(srv, {:bump, 5}) end, follow: [srv])

      assert "handle_call" in functions(tree)

      GenServer.stop(srv)
    end

    test "a name nobody registered is reported, and the trace still runs" do
      output =
        capture_io(:stderr, fn ->
          {result, tree} =
            CodeStory.narrate(fn -> CodeStory.TestSupport.SampleApp.add(1, 2) end,
              follow: [:nobody_registered_this]
            )

          assert result == 3
          assert "add" in functions(tree)
        end)

      assert output =~ "nobody_registered_this"
    end
  end

  describe "how a process may be named" do
    # A Registry hands out `{:via, Registry, {Name, key}}`, which is the form
    # most likely to be passed here and the one a hand-rolled resolver misses.
    test "a via-tuple from a Registry" do
      start_supervised!({Registry, keys: :unique, name: FollowRegistry})

      {:ok, srv} =
        Counter.start_link({:via, Registry, {FollowRegistry, :counter}})

      {_result, tree} =
        CodeStory.narrate(fn -> GenServer.call(srv, {:bump, 1}) end,
          follow: [{:via, Registry, {FollowRegistry, :counter}}]
        )

      assert "handle_call" in functions(tree)
    end

    # For a process with no name at all: work the pid out yourself.
    test "a zero-arity function returning the pid" do
      {:ok, srv} = Counter.start_link(:counter_by_fun)

      {_result, tree} =
        CodeStory.narrate(fn -> GenServer.call(srv, {:bump, 1}) end,
          follow: [fn -> Process.whereis(:counter_by_fun) end]
        )

      assert "handle_call" in functions(tree)

      GenServer.stop(srv)
    end

    test "a pid that has already died is reported, not attached" do
      {:ok, srv} = Counter.start_link(:counter_dead)
      GenServer.stop(srv)

      output =
        capture_io(:stderr, fn ->
          {result, _tree} =
            CodeStory.narrate(fn -> CodeStory.TestSupport.SampleApp.add(1, 2) end,
              follow: [srv]
            )

          assert result == 3
        end)

      assert output =~ "follow"
    end
  end

  describe "what stays the same" do
    test "no follow: behaves exactly as before" do
      {result, tree} =
        CodeStory.narrate(fn -> CodeStory.TestSupport.SampleApp.add_sub_mult(3, 2) end)

      assert result == 20
      assert [%{function: :add_sub_mult}] = tree
    end
  end

  defp functions(nodes) do
    Enum.flat_map(nodes, fn n ->
      [Atom.to_string(n.function) | functions(n.children || [])]
    end)
  end
end
