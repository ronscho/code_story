defmodule CodeStory.CheapArmingTest do
  @moduledoc """
  `values: false`: the trace keeps its shape and stops paying for the data.

  The option exists because the cost of a trace otherwise follows the **size of
  the data flowing through the program** rather than the number of calls --
  term copying loses sharing, so a hundred rows referencing one struct are
  copied out a hundred times.
  """

  use ExUnit.Case, async: false

  alias CodeStory.Collector
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

  describe "the tree keeps its shape" do
    test "calls, nesting and argument names survive" do
      {_, mit} = CodeStory.narrate(fn -> SampleApp.add_sub_mult(3, 2) end)
      {_, ohne} = CodeStory.narrate(fn -> SampleApp.add_sub_mult(3, 2) end, values: false)

      form = fn baum ->
        baum
        |> all_nodes()
        |> Enum.map(fn n -> {n.function, Enum.map(n.args, &elem(&1, 0))} end)
      end

      assert form.(ohne) == form.(mit)
    end

    test "return values are still there -- only the arguments go" do
      {_, tree} = CodeStory.narrate(fn -> SampleApp.add(3, 2) end, values: false)

      assert [%{function: :add, args: args, return: 5}] = tree
      assert args == [{:num1, Collector.no_value()}, {:num2, Collector.no_value()}]
    end

    test "a value that was not recorded renders as an ellipsis, not as an atom" do
      {_, tree} = CodeStory.narrate(fn -> SampleApp.add(3, 2) end, values: false)

      [encoded] = CodeStory.to_encodable(tree)

      assert Enum.map(encoded.args, & &1.value) == ["…", "…"]
      refute inspect(encoded) =~ "code_story_no_value"
    end
  end

  describe "what it is for" do
    # ⚠ The claim is not "somewhat cheaper". A traced call copies its arguments
    # onto the tracer's heap, so a big argument is paid for in full, once per
    # call. This measures that the payment stops.
    test "a large argument is not copied" do
      gross = Enum.to_list(1..50_000)

      groesse = fn opts ->
        {_, tree} = CodeStory.narrate(fn -> SampleApp.process_data(gross) end, opts)

        tree
        |> all_nodes()
        |> Enum.flat_map(fn n -> Enum.map(n.args, &elem(&1, 1)) end)
        |> Enum.map(&byte_size(:erlang.term_to_binary(&1)))
        |> Enum.sum()
      end

      mit = groesse.([])
      ohne = groesse.(values: false)

      assert mit > 100_000, "das grosse Argument sollte im Baum liegen, war #{mit} Bytes"
      assert ohne < 100, "ohne Werte darf nichts davon uebrig sein, war #{ohne} Bytes"
    end

    # ⚠⚠ The form worth reaching for on a real request: values where they are
    # worth reading, arity everywhere else. Trace flags are per process, so this
    # needs two trace sessions -- one function obeys the session it was armed
    # in, and both report to the same collector.
    test "a list of modules keeps their values and drops everyone else's" do
      gross = Enum.to_list(1..50_000)

      {_, tree} =
        CodeStory.narrate(
          fn ->
            SampleApp.process_data(gross)
            SampleApp.add(3, 2)
          end,
          values: [SampleApp]
        )

      nach_funktion = Map.new(all_nodes(tree), fn n -> {n.function, n.args} end)

      # SampleApp war gewaehlt -- seine Werte sind da.
      assert nach_funktion[:add] == [{:num1, 3}, {:num2, 2}]
      assert [{:data, ^gross}] = nach_funktion[:process_data]
    end

    test "an unchosen module keeps its names and loses its values" do
      {_, tree} =
        CodeStory.narrate(
          fn ->
            SampleApp.add(3, 2)
            CodeStory.TestSupport.SampleModule.add(1, 2)
          end,
          values: [CodeStory.TestSupport.SampleModule]
        )

      nach_modul = Map.new(all_nodes(tree), fn n -> {n.module, n.args} end)

      assert nach_modul[CodeStory.TestSupport.SampleModule] == [{:num1, 1}, {:num2, 2}]

      # ⚠ Die Namen bleiben, nur die Werte gehen -- der Baum sagt weiter, WAS
      # uebergeben wurde.
      leer = Collector.no_value()
      assert nach_modul[SampleApp] == [{:num1, leer}, {:num2, leer}]
    end

    test "record/collect takes the option too" do
      CodeStory.record(values: false)
      SampleApp.add(1, 2)

      assert [%{args: [{:num1, _}, {:num2, _}]} = node] = CodeStory.collect()
      assert Enum.all?(node.args, fn {_, v} -> v == Collector.no_value() end)
    end
  end
end
