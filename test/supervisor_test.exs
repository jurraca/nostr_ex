defmodule NostrEx.SupervisorTest do
  use ExUnit.Case

  test "exposes a supervisor child spec for embedding" do
    spec = Supervisor.child_spec({NostrEx.Supervisor, max_restarts: 10}, id: :nostr_test)
    assert spec.start == {NostrEx.Supervisor, :start_link, [[max_restarts: 10]]}
    assert spec.id == :nostr_test
  end

  test "is a singleton: a second start conflicts with the running tree" do
    assert {:error, {:already_started, pid}} = NostrEx.Supervisor.start_link([])
    assert Process.alive?(pid)
  end
end
