defmodule CodeStory.ManualRecordingTest do
  @moduledoc """
  `record/1` + `collect/0`: a trace that starts and finishes in different calls.

  `narrate/2` needs a block, and plenty of places have none -- a Plug that must
  arm at the head of a pipeline and read back in `register_before_send/2` is the
  case this was written for.
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

  defp all_nodes(tree), do: Enum.flat_map(tree, fn n -> [n | all_nodes(n.children)] end)
  defp functions(tree), do: tree |> all_nodes() |> Enum.map(& &1.function)

  test "records between the two calls and answers the tree" do
    assert :ok = CodeStory.record()

    assert SampleApp.add_sub_mult(3, 2) == 20

    tree = CodeStory.collect()

    assert :add_sub_mult in functions(tree)
    assert [%{module: SampleApp, function: :add_sub_mult} | _] = tree
  end

  test "the tree matches what narrate/2 produces for the same work" do
    CodeStory.record()
    SampleApp.add_sub_mult(3, 2)
    manual = CodeStory.collect()

    {_, block} = CodeStory.narrate(fn -> SampleApp.add_sub_mult(3, 2) end)

    assert functions(manual) == functions(block)
  end

  test "collect/0 leaves nothing armed, so a second recording is clean" do
    CodeStory.record()
    SampleApp.add(1, 2)
    first = CodeStory.collect()

    # ⚠ The guard that matters: if `collect/0` failed to disarm, the calls below
    # would land in a stale collector and the second tree would carry the first
    # one's calls too.
    CodeStory.record()
    SampleApp.subtract(9, 4)
    second = CodeStory.collect()

    assert functions(first) == [:add]
    assert functions(second) == [:subtract]
  end

  test "nothing runs between the calls means an empty tree" do
    CodeStory.record()

    assert CodeStory.collect() == []
  end

  test "a second record/1 is refused rather than joining the first" do
    CodeStory.record()

    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert CodeStory.record() == {:error, :already_tracing}
           end) =~ "already active"

    CodeStory.collect()
  end

  test "collect/0 without a recording warns and answers an empty tree" do
    assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
             assert CodeStory.collect() == []
           end) =~ "no active trace"
  end

  test "takes the same options as narrate/2" do
    CodeStory.record(extra_namespaces: ["OutsideNamespace"])
    OutsideNamespace.Mailer.deliver("hi")
    tree = CodeStory.collect()

    assert [%{module: OutsideNamespace.Mailer}] = all_nodes(tree)
  end
end
