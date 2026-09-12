defmodule CodeStory.ModuleLoadingTest do
  @moduledoc """
  A module that is not loaded when the trace starts still turns up in the tree,
  with `auto_boundary` either way.

  ⚠ Whether that holds everywhere is **open**. Measured under `mix test` a
  pattern set on such a module matched five functions; the same sequence under
  `mix run --no-start` matched none, and the trace came back empty. Same module
  state (`:code.is_loaded/1` false, `:code.which/1` finding it), same code path,
  different answer — the cause has not been found.

  ⓘ One thing that does load them is `Modules.ecto_repos/1`, which calls
  `Code.ensure_loaded?/1` on every module it is handed. That runs only when
  `auto_boundary` is on, so the two options do not reach arming by the same
  route. These tests pin the observable result while that stays unexplained.
  """
  use ExUnit.Case, async: false

  @tmp_ebin Path.expand("../../tmp/loading_test_ebin", __DIR__)

  setup_all do
    File.mkdir_p!(@tmp_ebin)
    true = Code.append_path(@tmp_ebin)

    on_exit(fn ->
      Code.delete_path(@tmp_ebin)
      File.rm_rf(@tmp_ebin)
    end)

    :ok
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

  # Puts a module on disk under the app's own namespace and takes it back out of
  # memory, which is the state a module is in before anything calls it.
  defp lay_out_unloaded(name) do
    module = Module.concat(CodeStory, name)

    [{^module, binary}] =
      Code.compile_string("defmodule #{inspect(module)} do\n  def f(x), do: x + 1\nend")

    File.write!(Path.join(@tmp_ebin, "#{module}.beam"), binary)
    unload(module)

    module
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
  end

  describe "a module that is not loaded when the trace starts" do
    test "is traced with auto_boundary on" do
      module = lay_out_unloaded(:LoadingProbeOn)

      assert :code.is_loaded(module) == false

      {result, tree} = CodeStory.narrate(fn -> apply(module, :f, [1]) end, auto_boundary: true)

      assert result == 2
      assert [%{function: :f}] = tree
    end

    # The same thing, and it used to come back empty: nothing had loaded the
    # module, so nothing could arm it.
    test "is traced with auto_boundary off, too" do
      module = lay_out_unloaded(:LoadingProbeOff)

      assert :code.is_loaded(module) == false

      {result, tree} = CodeStory.narrate(fn -> apply(module, :f, [1]) end, auto_boundary: false)

      assert result == 2
      assert [%{function: :f}] = tree
    end
  end
end
