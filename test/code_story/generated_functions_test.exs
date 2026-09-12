defmodule CodeStory.GeneratedFunctionsTest do
  @moduledoc """
  Compiler-generated entries stay out of the trace.

  An anonymous function becomes its own entry in `module_info(:functions)`,
  named `-caller/arity-fun-0-`. It is an artefact of compilation, not something
  anyone wrote, and it has no place in a story about the code.

  ⚠ Where it gets excluded matters. Enumerating a module's functions and
  skipping those entries kept them out by never arming them — but enumerating is
  what makes starting a trace slow, and arming a module with `{Mod, :_, :_}`
  cannot skip anything. So the filter belongs where the events arrive, and this
  file is what keeps it honest: the observable result must not change.
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

  test "the module really does carry a generated entry" do
    # A guard on the premise: if the compiler ever stops emitting these, the
    # test below would pass for the wrong reason.
    generated =
      SampleApp.module_info(:functions)
      |> Enum.filter(fn {fun, _} -> fun |> Atom.to_string() |> String.starts_with?("-") end)

    assert generated != []
  end

  test "a generated entry does not appear in the tree" do
    {result, tree} = CodeStory.narrate(fn -> SampleApp.with_anonymous_fun([1, 2, 3]) end)

    assert result == [2, 4, 6]
    assert [%{function: :with_anonymous_fun} = root] = tree

    namen = Enum.map(root.children, &Atom.to_string(&1.function))
    refute Enum.any?(namen, &String.starts_with?(&1, "-"))
  end
end
