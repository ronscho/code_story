defmodule CodeStory.SpawnedProcessTest do
  @moduledoc """
  Work done in a process the traced code spawns belongs in the trace.

  `:trace.process/4` attaches to one process. Anything that process spawns runs
  unwatched, so a `Task.async/await` pair shows the caller waiting and nothing
  of what it waited for. In a Phoenix/Absinthe request that is not an edge case:
  Dataloader resolves its batches through `Task.async_stream`, so the queries a
  request actually runs are exactly the part that goes missing -- while the
  trace still looks complete.

  `:set_on_spawn` makes the runtime propagate the flags, so the recursion needs
  no code. What does need code is keeping the processes apart while their events
  interleave, and putting the child's tree back where it belongs.
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

  describe "a spawned process" do
    test "its calls are recorded" do
      {result, tree} = CodeStory.narrate(fn -> SampleApp.in_a_task(4) end)

      assert result == 8
      assert "add" in functions(tree)
    end

    test "its calls hang under the call that spawned it" do
      {_, tree} = CodeStory.narrate(fn -> SampleApp.in_a_task(4) end)

      assert [%{function: :in_a_task} = root] = tree
      assert "add" in functions(root.children)
    end

    test "a process spawned by a spawned process is recorded too" do
      {result, tree} = CodeStory.narrate(fn -> SampleApp.in_a_nested_task(4) end)

      assert result == 8
      assert "in_a_task" in functions(tree)
      assert "add" in functions(tree)
    end

    # Siblings are kept apart by the same thing that places them: the anchor is
    # taken from the PARENT's stack at spawn time, not from whatever happens to
    # be open somewhere. Three tasks started under one call therefore become
    # three siblings -- asserted structurally, because "all three names appear"
    # would also pass if one had swallowed the others.
    test "concurrent processes become siblings, not each other's children" do
      {result, tree} = CodeStory.narrate(fn -> SampleApp.in_parallel_tasks(10) end)

      assert result == [11, 9, 20]
      assert [%{function: :in_parallel_tasks, children: children}] = tree
      assert Enum.map(children, & &1.function) == [:add, :subtract, :mult]

      # And none of them carries any of the others underneath it.
      for child <- children do
        assert child.children == []
      end
    end

    # The other direction: a spawn inside a spawn nests, rather than flattening
    # into the caller's sequence.
    test "a nested spawn nests" do
      {_result, tree} = CodeStory.narrate(fn -> SampleApp.in_a_nested_task(4) end)

      assert [%{function: :in_a_nested_task, children: [inner]}] = tree
      assert inner.function == :in_a_task
      assert Enum.map(inner.children, & &1.function) == [:add]
    end
  end

  describe "a process that outlives the region" do
    # The drain waits for spawned processes to exit, because an exit event is
    # ordered behind that process's own calls. A child that never exits must
    # therefore not hold the trace hostage.
    test "does not hang the trace" do
      {elapsed, {result, tree}} =
        :timer.tc(fn -> CodeStory.narrate(fn -> SampleApp.detached_task(4) end) end)

      assert result == :started
      assert [%{function: :detached_task}] = tree

      # The child sleeps for 2 s. Bounded by the ceiling, not by the child.
      assert elapsed < 1_000_000
    end
  end

  describe "what stays the same" do
    test "a fun that spawns nothing is unchanged" do
      {result, tree} = CodeStory.narrate(fn -> SampleApp.add_sub_mult(3, 2) end)

      assert result == 20
      assert [%{function: :add_sub_mult} = root] = tree
      assert Enum.map(root.children, & &1.function) == [:add, :subtract, :mult]
    end
  end

  defp functions(nodes) do
    Enum.flat_map(nodes, fn n ->
      [Atom.to_string(n.function) | functions(n.children || [])]
    end)
  end
end
