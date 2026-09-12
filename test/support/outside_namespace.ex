defmodule OutsideNamespace.Mailer do
  @moduledoc """
  Stands in for app code that does not live under the app-name prefix.

  A real project's mailer, API client or extracted core sits here: compiled into
  the same application, invisible to a prefix rule. The namespace is deliberately
  unrelated to `CodeStory` -- if it shared a head, it would prove nothing.
  """

  @doc "Hands back what it was given, so a trace has an argument and a return."
  @spec deliver(term()) :: {:sent, term()}
  def deliver(message), do: {:sent, message}
end
