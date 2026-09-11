defmodule CodeStory.DeclaredBoundaryTest do
  @moduledoc """
  `boundaries:` lets a caller say where the edge of their core is.

  The collector always took an arbitrary list of boundary modules and did the
  right thing with any of them — suppress the interior, tag the entry. Only the
  plumbing disagreed: `do_start/1` overwrote the list with `auto_boundary`'s
  findings, so a declared one was discarded without a word.

  Detecting Ecto repos is a good default and not the whole story. Where a core
  ends and a boundary begins is a **design decision** — the author's, not a
  property the tool can sniff out of a module. A context, an adapter, a client
  wrapper: all boundaries by intent, none of them detectable.

  With one declared, a trace reads the way the system was designed: the core
  expanded, the crossing as a single edge.
  """
  use ExUnit.Case, async: false

  defmodule Core do
    @moduledoc false
    def compute(x), do: step(x) + step(x)
    defp step(x), do: x * 2
  end

  defmodule Edge do
    @moduledoc false
    def fetch(x), do: inner_a(x) + inner_b(x)
    defp inner_a(x), do: x + 1
    defp inner_b(x), do: x + 2
  end

  defmodule App do
    @moduledoc false
    def run(x), do: Core.compute(x) + Edge.fetch(x)

    def run_with_repo(x) do
      Edge.fetch(x)
      CodeStory.TestSupport.FakeRepo.get(x)
    end
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

  describe "a declared boundary" do
    test "keeps its entry and hides what is behind it" do
      {_result, tree} =
        CodeStory.narrate(fn -> App.run(3) end, boundaries: [Edge])

      assert [%{function: :run, children: [core, edge]}] = tree

      # The core stays open — that is the half you are reading.
      assert core.function == :compute
      assert Enum.map(core.children, & &1.function) == [:step, :step]

      # The crossing is one node, tagged, with nothing underneath.
      assert edge.function == :fetch
      assert edge.children == []
      assert edge.boundary == true
    end

    test "without it, the same call is fully expanded" do
      {_result, tree} = CodeStory.narrate(fn -> App.run(3) end)

      assert [%{children: [_core, edge]}] = tree
      assert Enum.map(edge.children, & &1.function) == [:inner_a, :inner_b]
      refute Map.has_key?(edge, :boundary)
    end
  end

  describe "declared and detected" do
    # A repo is a boundary too. Declaring one of your own must not cost you the
    # ones the tool finds.
    test "add up" do
      {_result, tree} =
        CodeStory.narrate(fn -> App.run_with_repo(3) end, boundaries: [Edge])

      assert [%{children: children}] = tree
      assert Enum.all?(children, & &1.boundary)
      assert Enum.map(children, & &1.function) == [:fetch, :get]
    end

    test "auto_boundary: false leaves only what was declared" do
      {_result, tree} =
        CodeStory.narrate(fn -> App.run_with_repo(3) end,
          boundaries: [Edge],
          auto_boundary: false
        )

      assert [%{children: [edge, repo]}] = tree
      assert edge.boundary == true
      # The repo is now ordinary code, so its interior shows.
      refute Map.has_key?(repo, :boundary)
    end
  end
end
