defmodule CodeStory.TimingTest do
  @moduledoc """
  `timing: true` puts how long each call took on its node.

  A call tree already says what happened and in what order. What it cannot say
  is where the time went — and that is usually the next question, because the
  shape of a trace rarely predicts its cost: a node with one child can dominate
  a node with fifty.

  ⚠ Off by default, and not only out of caution. The `:timestamp` process flag
  makes the runtime stamp every trace message, which is work per call; a trace
  read for structure should not pay for it. Turning it on also changes the node
  shape, and a caller pattern-matching the documented five keys should not have
  that happen behind their back.

  ⚠ A duration measured this way is **total** — the call and everything beneath
  it — and it includes the tracing overhead of everything beneath it. Useful for
  comparing siblings, misleading as a benchmark.
  """
  use ExUnit.Case, async: false

  alias CodeStory.TestSupport.SampleApp

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

  describe "with timing: true" do
    test "every node carries a duration in microseconds" do
      {_result, tree} = CodeStory.narrate(fn -> SampleApp.add_sub_mult(3, 2) end, timing: true)

      assert [root] = tree
      assert is_integer(root.duration)
      assert root.duration >= 0

      for child <- root.children do
        assert is_integer(child.duration)
      end
    end

    test "a call that sleeps measures at least as long as it slept" do
      {_result, tree} = CodeStory.narrate(fn -> SampleApp.slow(5) end, timing: true)

      assert [root] = tree
      # 5 ms of sleep, in microseconds, with room for scheduling.
      assert root.duration >= 5_000
      assert root.duration < 500_000
    end

    test "a parent takes at least as long as its children together" do
      {_result, tree} = CodeStory.narrate(fn -> SampleApp.add_sub_mult(3, 2) end, timing: true)

      assert [root] = tree
      kinder = Enum.map(root.children, & &1.duration) |> Enum.sum()

      assert root.duration >= kinder
    end
  end

  describe "together with spawned processes" do
    # ⚠ `:timestamp` turns EVERY message into its `_ts` variant, including the
    # `:procs` ones a spawn produces (`:spawn`, `:spawned`, `:exit`). The plain
    # catch-alls do not match those, so this combination crashed the collector
    # while each feature on its own was green. Neither test suite covered it:
    # the timing tests spawned nothing, the spawn tests measured nothing.
    test "a trace that spawns and measures survives both" do
      {result, tree} = CodeStory.narrate(fn -> SampleApp.in_a_task(4) end, timing: true)

      assert result == 8
      assert [%{function: :in_a_task, duration: d} = root] = tree
      assert is_integer(d)
      assert "add" in Enum.map(root.children, &Atom.to_string(&1.function))
    end
  end

  describe "without it" do
    test "the node shape is exactly what narrate/2 documents" do
      {_result, tree} = CodeStory.narrate(fn -> SampleApp.add(1, 2) end)

      assert [root] = tree

      assert Map.keys(root) |> Enum.sort() ==
               [:args, :children, :function, :module, :return]
    end
  end
end
