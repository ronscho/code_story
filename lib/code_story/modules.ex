defmodule CodeStory.Modules do
  @moduledoc """
  Auto-detects user-defined modules from the host project's mix.exs app name.

  The app name is a good default and not a complete answer: code that belongs to
  the app but sits under a different top-level namespace is invisible to it.
  `detect/1` takes those namespaces as an argument.
  """

  @doc """
  Converts an app atom to its expected module prefix string.

  ## Examples

      iex> CodeStory.Modules.camelize_app_name(:my_app)
      "MyApp"
  """
  def camelize_app_name(app) when is_atom(app) do
    app
    |> Atom.to_string()
    |> Macro.camelize()
  end

  @doc """
  Detects user-defined modules from the current Mix project.

  Returns a list of modules whose top-level namespace matches the
  app name from `Mix.Project.config()[:app]`, including the app's
  Web namespace (e.g. `:my_app` matches `MyApp.*` and `MyAppWeb.*`,
  the conventional Phoenix split).

  `extra` names further top-level namespaces to include, for the code in your
  app that does not live under the app-name prefix. That is common enough to be
  worth an option: a mailer under `EmailService`, an API client under
  `StripeApi`, a shared `Core` extracted but not yet its own app. Those modules
  are as much "your code" as `MyApp.*` is, and the prefix rule cannot see them.

      CodeStory.Modules.detect(["EmailService", "StripeApi"])

  ⚠ The symptom when a namespace is missing is not an error — it is a trace in
  which those calls are simply **absent**, which reads like the code never ran.
  Accepts strings or module aliases (`EmailService` and `"EmailService"` are the
  same namespace).
  """
  @spec detect([String.t() | module()]) :: [module()]
  def detect(extra \\ []) do
    app = Mix.Project.config()[:app]
    prefix = camelize_app_name(app)
    namespaces = MapSet.new([prefix, prefix <> "Web" | Enum.map(extra, &namespace/1)])

    :code.all_available()
    |> Enum.map(fn {mod_charlist, _path, _loaded} -> List.to_atom(mod_charlist) end)
    |> Enum.filter(&elixir_module?/1)
    |> Enum.filter(fn mod -> MapSet.member?(namespaces, hd(Module.split(mod))) end)
    |> Enum.reject(&code_story_module?/1)
  end

  # An alias arrives as the atom :"Elixir.EmailService"; a string arrives as
  # written. `Module.split/1` compares against the written head either way.
  defp namespace(name) when is_binary(name), do: name
  defp namespace(name) when is_atom(name), do: hd(Module.split(name))

  @doc """
  Filters the given modules to those that are Ecto repos.

  Detection is runtime duck-typing — a repo is any module exporting
  `__adapter__/0` (which `use Ecto.Repo` defines). CodeStory has **no**
  compile-time dependency on Ecto.

  `Code.ensure_loaded?/1` is required: `function_exported?/3` returns `false`
  for a merely-loadable-but-unloaded module and will not load it, and detection
  can run before the tracer forces modules to load.
  """
  @spec ecto_repos([module()]) :: [module()]
  def ecto_repos(modules) do
    # ⚠ One call rather than one per module. `function_exported?/3` needs the
    # module loaded, so the loading has to happen either way -- but
    # `:code.ensure_modules_loaded/1` does the whole list at once. Measured on a
    # 286-module application with 282 of them not yet loaded: 125 ms per-module
    # against 58 ms in one call, for the same result.
    #
    # ⓘ It answers `{:error, [{Module, Reason}, ...]}` for whatever could not be
    # loaded, which is not an error here: a module that will not load simply
    # cannot export `__adapter__/0`, and `function_exported?/3` says so on its
    # own.
    _ = :code.ensure_modules_loaded(modules)

    Enum.filter(modules, &function_exported?(&1, :__adapter__, 0))
  end

  @code_story_modules [
    CodeStory,
    CodeStory.Modules,
    CodeStory.Args,
    CodeStory.Collector,
    CodeStory.Tracer,
    CodeStory.Formatter
  ]

  defp code_story_module?(mod) do
    mod in @code_story_modules
  end

  defp elixir_module?(mod) do
    # Elixir modules are atoms starting with "Elixir."
    # Erlang modules like :proplists, :ets, etc. do not have this prefix
    mod |> Atom.to_string() |> String.starts_with?("Elixir.")
  end
end
