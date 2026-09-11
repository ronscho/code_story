defmodule CodeStory.MultiRootTest do
  @moduledoc """
  A traced region may contain more than one top-level call, and all of them
  belong in the trace.

  The collector used to finish on the **first** root that returned: a real node
  with no real ancestor set `status: {:completed, tree}`, and every later event
  was discarded. That made `tell/0` + `stop/0` unable to do the one thing it
  exists for -- bracketing a region -- and it silently truncated block form too,
  which is worse, because the output looks complete.

  It also made the tool nearly blind inside a framework. When the entry point is
  library code that is not itself traced (a GraphQL runtime, a Plug pipeline),
  the user's own functions are reached as a *sequence* of roots; the first one
  to return ended the story before the interesting ones happened.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

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

  describe "block form" do
    test "records every top-level call, not only the first" do
      output =
        capture_io(fn ->
          CodeStory.tell(fn ->
            SampleApp.add(1, 2)
            SampleApp.subtract(9, 4)
            SampleApp.mult(3, 3)
          end)
        end)

      assert output =~ "add"
      assert output =~ "subtract"
      assert output =~ "mult"
    end

    test "keeps the roots in the order they were called" do
      output =
        capture_io(fn ->
          CodeStory.tell(fn ->
            SampleApp.add(1, 2)
            SampleApp.subtract(9, 4)
          end)
        end)

      assert index(output, "add") < index(output, "subtract")
    end

    test "a later root keeps its own children" do
      output =
        capture_io(fn ->
          CodeStory.tell(fn ->
            SampleApp.add(1, 2)
            SampleApp.add_sub_mult(3, 2)
          end)
        end)

      # `add_sub_mult` is the second root and calls three functions beneath it.
      assert output =~ "add_sub_mult"
      assert output =~ "subtract"
      assert output =~ "mult"
    end

    test "one root still produces exactly the trace it did before" do
      output = capture_io(fn -> CodeStory.tell(fn -> SampleApp.add_sub_mult(3, 2) end) end)

      assert output =~ "CodeStory Trace"
      assert output =~ "add_sub_mult"
    end
  end

  describe "manual form" do
    test "brackets a region holding several calls" do
      :ok = CodeStory.tell()

      SampleApp.add(1, 2)
      SampleApp.subtract(9, 4)

      output = capture_io(fn -> CodeStory.stop() end)

      assert output =~ "add"
      assert output =~ "subtract"
    end
  end

  defp index(output, needle) do
    [{position, _}] = Regex.run(~r/#{needle}/, output, return: :index)
    position
  end
end
