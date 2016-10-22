alias Experimental.GenStage

defmodule GenStage.BroadcastDispatcherTest do
  use ExUnit.Case, async: true

  alias GenStage.BroadcastDispatcher, as: D

  defp dispatcher(opts) do
    {:ok, {[], 0} = state} = D.init(opts)
    state
  end

  test "subscribes and cancels" do
    pid  = self()
    ref  = make_ref()
    disp = dispatcher([])

    {:ok, 0, disp} = D.subscribe([], {pid, ref}, disp)
    assert disp == {[{0, pid, ref, nil}], 0}

    {:ok, 0, disp} = D.cancel({pid, ref}, disp)
    assert disp == {[], 0}
  end

  test "multiple subscriptions with early demand" do
    pid  = self()
    ref1 = make_ref()
    ref2 = make_ref()
    disp = dispatcher([])

    {:ok, 0, disp} = D.subscribe([], {pid, ref1}, disp)
    assert disp == {[{0, pid, ref1, nil}], 0}

    {:ok, 10, disp} = D.ask(10, {pid, ref1}, disp)
    assert disp == {[{0, pid, ref1, nil}], 10}

    {:ok, 0, disp} = D.subscribe([], {pid, ref2}, disp)
    assert disp == {[{-10, pid, ref2, nil}, {0, pid, ref1, nil}], 10}

    {:ok, 0, disp} = D.cancel({pid, ref1}, disp)
    assert disp == {[{-10, pid, ref2, nil}], 10}

    {:ok, 0, disp} = D.ask(10, {pid, ref2}, disp)
    assert disp == {[{0, pid, ref2, nil}], 10}
  end

  test "multiple subscriptions with late demand" do
    pid  = self()
    ref1 = make_ref()
    ref2 = make_ref()
    disp = dispatcher([])

    {:ok, 0, disp} = D.subscribe([], {pid, ref1}, disp)
    assert disp == {[{0, pid, ref1, nil}], 0}

    {:ok, 0, disp} = D.subscribe([], {pid, ref2}, disp)
    assert disp == {[{0, pid, ref2, nil}, {0, pid, ref1, nil}], 0}

    {:ok, 0, disp} = D.ask(10, {pid, ref1}, disp)
    assert disp == {[{10, pid, ref1, nil}, {0, pid, ref2, nil}], 0}

    {:ok, 10, disp} = D.cancel({pid, ref2}, disp)
    assert disp == {[{0, pid, ref1, nil}], 10}

    {:ok, 10, disp} = D.ask(10, {pid, ref1}, disp)
    assert disp == {[{0, pid, ref1, nil}], 20}
  end

  test "subscribes, asks and dispatches to multiple consumers" do
    pid  = self()
    ref1 = make_ref()
    ref2 = make_ref()
    ref3 = make_ref()
    disp = dispatcher([])

    {:ok, 0, disp} = D.subscribe([], {pid, ref1}, disp)
    {:ok, 0, disp} = D.subscribe([], {pid, ref2}, disp)

    {:ok, 0, disp} = D.ask(3, {pid, ref1}, disp)
    {:ok, 2, disp} = D.ask(2, {pid, ref2}, disp)
    assert disp == {[{0, pid, ref2, nil}, {1, pid, ref1, nil}], 2}

    # One batch fits all
    {:ok, [], disp} = D.dispatch([:a, :b], disp)
    assert disp == {[{0, pid, ref2, nil}, {1, pid, ref1, nil}], 0}
    assert_received {:"$gen_consumer", {_, ^ref1}, [:a, :b]}
    assert_received {:"$gen_consumer", {_, ^ref2}, [:a, :b]}

    # A batch with left-over
    {:ok, 1, disp} = D.ask(2, {pid, ref2}, disp)
    {:ok, [:d], disp} = D.dispatch([:c, :d], disp)
    assert disp == {[{1, pid, ref2, nil}, {0, pid, ref1, nil}], 0}
    assert_received {:"$gen_consumer", {_, ^ref1}, [:c]}
    assert_received {:"$gen_consumer", {_, ^ref2}, [:c]}

    # A batch with no demand
    {:ok, [:d], disp} = D.dispatch([:d], disp)
    assert disp == {[{1, pid, ref2, nil}, {0, pid, ref1, nil}], 0}
    refute_received {:"$gen_consumer", {_, _}, _}

    # Add a late subscriber
    {:ok, 1, disp} = D.ask(1, {pid, ref1}, disp)
    {:ok, 0, disp} = D.subscribe([], {pid, ref3}, disp)
    assert disp == {[{-1, pid, ref3, nil}, {0, pid, ref1, nil}, {0, pid, ref2, nil}], 1}
    {:ok, [:e], disp} = D.dispatch([:d, :e], disp)
    assert_received {:"$gen_consumer", {_, ^ref1}, [:d]}
    assert_received {:"$gen_consumer", {_, ^ref2}, [:d]}
    assert_received {:"$gen_consumer", {_, ^ref3}, [:d]}

    # Even out
    {:ok, 0, disp} = D.ask(2, {pid, ref1}, disp)
    {:ok, 0, disp} = D.ask(2, {pid, ref2}, disp)
    {:ok, 2, disp} = D.ask(3, {pid, ref3}, disp)
    {:ok, [], disp} = D.dispatch([:e, :f], disp)
    assert disp == {[{0, pid, ref3, nil}, {0, pid, ref2, nil}, {0, pid, ref1, nil}], 0}
    assert_received {:"$gen_consumer", {_, ^ref1}, [:e, :f]}
    assert_received {:"$gen_consumer", {_, ^ref2}, [:e, :f]}
    assert_received {:"$gen_consumer", {_, ^ref3}, [:e, :f]}
  end

  test "subscribing with a selector function" do
    pid  = self()
    ref1 = make_ref()
    ref2 = make_ref()
    disp = dispatcher([])
    selector1 = fn %{key: key} -> String.starts_with?(key, "pre") end
    selector2 = fn %{key: key} -> String.starts_with?(key, "pref") end

    {:ok, 0, disp} = D.subscribe([selector: selector1], {pid, ref1}, disp)
    {:ok, 0, disp} = D.subscribe([selector: selector2], {pid, ref2}, disp)
    assert {[{0, ^pid, ^ref2, _selector2}, {0, ^pid, ^ref1, _selector1}], 0} = disp
    {:ok, 0, disp} = D.ask(4, {pid, ref2}, disp)
    {:ok, 4, disp} = D.ask(4, {pid, ref1}, disp)

    {:ok, [], _disp} = D.dispatch([%{key: "pref-1234"}, %{key: "pref-5678"}, %{key: "pre0000"}, %{key: "foo0000"}], disp)

    assert_received {:"$gen_consumer", {_, ^ref2}, [%{key: "pref-1234"}, %{key: "pref-5678"}]}
    assert_received {:"$gen_consumer", {_, ^ref1}, [%{key: "pref-1234"}, %{key: "pref-5678"}, %{key: "pre0000"}]}
  end

  test "delivers notifications to all consumers" do
    pid  = self()
    ref1 = make_ref()
    ref2 = make_ref()
    disp = dispatcher([])

    {:ok, 0, disp} = D.subscribe([], {pid, ref1}, disp)
    {:ok, 0, disp} = D.subscribe([], {pid, ref2}, disp)
    {:ok, 0, disp} = D.ask(3, {pid, ref1}, disp)

    {:ok, notify_disp} = D.notify(:hello, disp)
    assert disp == notify_disp

    assert_received {:"$gen_consumer", {_, ^ref1}, {:notification, :hello}}
    assert_received {:"$gen_consumer", {_, ^ref2}, {:notification, :hello}}
  end
end
