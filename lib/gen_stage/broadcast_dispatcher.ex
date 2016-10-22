alias Experimental.GenStage

defmodule GenStage.BroadcastDispatcher do
  @moduledoc """
  A dispatcher that accumulates demand from all consumers
  before broadcasting events to all of them.

  If a producer uses BroadcastDispatcher, its subscribers can specify
  an optional `:selector` function of type (event :: any -> boolean)
  at subscription time.

  Assume `producer` and `consumer` are stages exchanging events of type
  `%{ :key => String.t, any => any}`, then by specifying

      GenStage.sync_subscribe(producer,
        to: producer,
        selector: fn %{key: key} -> String.starts_with?(key, "foo-") end)

  `consumer` will receive events from `producer` only if the condition specified
  in the selector function returns true.

  """

  @behaviour GenStage.Dispatcher

  @doc false
  def init(_opts) do
    {:ok, {[], 0}}
  end

  @doc false
  def notify(msg, {demands, _} = state) do
    Enum.each(demands, fn {_, pid, ref, _selector} ->
      Process.send(pid, {:"$gen_consumer", {self(), ref}, {:notification, msg}}, [:noconnect])
    end)
    {:ok, state}
  end

  @doc false
  def subscribe(opts, {pid, ref}, {demands, waiting}) do
    {:ok, selector} = validate_selector(opts)
    {:ok, 0, {add_demand(-waiting, pid, ref, selector, demands), waiting}}
  end

  @doc false
  def cancel({_, ref}, {demands, waiting}) do
    # Since we may have removed the process we were waiting on,
    # cancellation may actually generate demand!
    demands = delete_demand(ref, demands)
    new_min = get_min(demands)
    demands = adjust_demand(new_min, demands)
    {:ok, new_min, {demands, waiting + new_min}}
  end

  @doc false
  def ask(counter, {pid, ref}, {demands, waiting}) do
    {{current, selector}, demands} = pop_demand(ref, demands)
    demands = add_demand(current + counter, pid, ref, selector, demands)
    new_min = get_min(demands)
    demands = adjust_demand(new_min, demands)
    {:ok, new_min, {demands, waiting + new_min}}
  end

  @doc false
  def dispatch(events, {demands, 0}) do
    {:ok, events, {demands, 0}}
  end

  def dispatch(events, {demands, waiting}) do
    {deliver_now, deliver_later, waiting} =
      split_events(events, waiting, [])
    Enum.each(demands, fn {_, pid, ref, selector} ->
      selected = if selector, do: Enum.filter(deliver_now, selector), else: deliver_now
      Process.send(pid, {:"$gen_consumer", {self(), ref}, selected}, [:noconnect])
    end)

    {:ok, deliver_later, {demands, waiting}}
  end

  defp validate_selector(opts) do
    case Keyword.get(opts, :selector) do
      nil -> {:ok, nil}
      selector when is_function(selector, 1) ->
        {:ok, selector}
      something_else ->
        :error_logger.error_msg(':selector option must be passed a unary function and not: ~p~n', [something_else])
        {:error, :not_a_unary_function}
    end
  end

  defp get_min([]),
    do: 0
  defp get_min([{acc, _, _, _} | demands]),
    do: demands |> Enum.reduce(acc, fn {val, _, _, _}, acc -> min(val, acc) end) |> max(0)

  defp split_events(events, 0, acc),
    do: {:lists.reverse(acc), events, 0}
  defp split_events([], counter, acc),
    do: {:lists.reverse(acc), [], counter}
  defp split_events([event | events], counter, acc),
    do: split_events(events, counter - 1, [event | acc])

  defp adjust_demand(0, demands),
    do: demands
  defp adjust_demand(min, demands),
    do: Enum.map(demands, fn {counter, pid, key, selector} -> {counter - min, pid, key, selector} end)

  defp add_demand(counter, pid, ref, selector, demands)
  when is_integer(counter) and is_pid(pid) and (is_nil(selector) or is_function(selector, 1)) do
    [{counter, pid, ref, selector} | demands]
  end

  defp pop_demand(ref, demands) do
    case List.keytake(demands, ref, 2) do
      {{current, _pid, ^ref, selector}, rest} -> {{current, selector}, rest}
      nil -> {{0, nil}, demands}
    end
  end

  defp delete_demand(ref, demands) do
    List.keydelete(demands, ref, 2)
  end
end
