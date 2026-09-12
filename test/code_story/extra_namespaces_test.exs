defmodule CodeStory.ExtraNamespacesTest do
  @moduledoc """
  `extra_namespaces:` end to end: does the option actually arm the module.

  The unit tests in `CodeStory.ModulesTest` prove detection returns the module.
  These prove the trace contains its calls -- which is the thing a user asks
  for, and the thing whose absence is silent.
  """

  use ExUnit.Case, async: false

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
  defp modules(tree), do: tree |> all_nodes() |> Enum.map(& &1.module) |> Enum.uniq()

  test "without the option the outside call is missing from the trace" do
    {_, tree} = CodeStory.narrate(fn -> OutsideNamespace.Mailer.deliver("hi") end)

    refute OutsideNamespace.Mailer in modules(tree)
  end

  test "with the option the outside call is traced, args and return included" do
    {result, tree} =
      CodeStory.narrate(fn -> OutsideNamespace.Mailer.deliver("hi") end,
        extra_namespaces: ["OutsideNamespace"]
      )

    assert result == {:sent, "hi"}

    assert [node] = all_nodes(tree)
    assert node.module == OutsideNamespace.Mailer
    assert node.function == :deliver
    assert node.args == [{:message, "hi"}]
    assert node.return == {:sent, "hi"}
  end

  test "the app's own namespace stays armed alongside" do
    {_, tree} =
      CodeStory.narrate(
        fn ->
          CodeStory.TestSupport.SampleApp.add_sub_mult(3, 2)
          OutsideNamespace.Mailer.deliver("hi")
        end,
        extra_namespaces: [OutsideNamespace]
      )

    modules = modules(tree)

    assert CodeStory.TestSupport.SampleApp in modules
    assert OutsideNamespace.Mailer in modules
  end
end
