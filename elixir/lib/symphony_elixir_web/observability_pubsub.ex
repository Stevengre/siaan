defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated
  @test_recipient_key {__MODULE__, :test_recipient}

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec broadcast_update() :: :ok
  def broadcast_update do
    notify_test_recipient()

    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @topic, @update_message)

      _ ->
        :ok
    end
  end

  @doc false
  @spec put_test_recipient(pid()) :: :ok
  def put_test_recipient(pid) when is_pid(pid) do
    Process.put(@test_recipient_key, pid)
    :ok
  end

  @doc false
  @spec clear_test_recipient() :: :ok
  def clear_test_recipient do
    Process.delete(@test_recipient_key)
    :ok
  end

  defp notify_test_recipient do
    case Process.get(@test_recipient_key) do
      pid when is_pid(pid) -> send(pid, :observability_broadcast)
      _ -> :ok
    end
  end
end
