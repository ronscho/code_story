defmodule CodeStory.TestSupport.SampleApp do
  @moduledoc false

  def add_sub_mult(num1, num2) do
    num1
    |> add(num2)
    |> subtract(1)
    |> mult(5)
  end

  def add(num1, num2), do: num1 + num2

  def subtract(num1, num2), do: num1 - num2

  def mult(num1, num2), do: num1 * num2

  def divide(num1, num2), do: div(num1, num2)

  def do_stuff(num1, num2) do
    number = num1 * num2
    number_2 = divide(number, num1)
    "hello #{number_2}"
  end

  def recursive_countdown(0), do: :done
  def recursive_countdown(n), do: recursive_countdown(n - 1)

  def process_data(data), do: data

  # Calls `add/2` three times as consecutive siblings — a repeated-sibling run
  # that `CodeStory.Fold` collapses (unlike `recursive_countdown`, which nests).
  def repeat_add(x) do
    [add(x, x), add(x, x), add(x, x)]
  end

  # Entry that crosses into a boundary module (FakeRepo duck-types an Ecto repo).
  def fetch_via_repo(id) do
    CodeStory.TestSupport.FakeRepo.get(id)
  end

  # Public entry delegating to a private helper — verifies that defp
  # functions appear in traces.
  def describe_number(n) do
    classify(n)
  end

  defp classify(n) when n >= 0, do: {:non_negative, n}
  defp classify(n), do: {:negative, n}

  # Spawns a task and waits for it. The work happens in another process, so a
  # tracer that only follows the caller sees the `Task.await` and nothing of
  # what was awaited.
  def in_a_task(x) do
    task = Task.async(fn -> add(x, x) end)
    Task.await(task)
  end

  # Two levels deep: the task spawns a task of its own.
  def in_a_nested_task(x) do
    task = Task.async(fn -> in_a_task(x) end)
    Task.await(task)
  end

  # Several tasks at once — their events interleave in the collector's mailbox,
  # so each process needs its own stack or the trees bleed into each other.
  def in_parallel_tasks(x) do
    [fn -> add(x, 1) end, fn -> subtract(x, 1) end, fn -> mult(x, 2) end]
    |> Enum.map(&Task.async/1)
    |> Enum.map(&Task.await/1)
  end

  # Spawns and does NOT wait. The child outlives the traced region, so its exit
  # is never seen — the drain has to give up on it rather than hang.
  def detached_task(x) do
    Task.start(fn ->
      Process.sleep(2_000)
      add(x, x)
    end)

    :started
  end

  # A spawned process whose only call is into a boundary module.
  def boundary_only_task(id) do
    task = Task.async(fn -> CodeStory.TestSupport.FakeRepo.get(id) end)
    Task.await(task)
  end
end
