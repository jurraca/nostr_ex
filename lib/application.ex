defmodule NostrEx.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    if Application.get_env(:nostr_ex, :autostart, true) do
      NostrEx.Supervisor.start_link(Application.get_env(:nostr_ex, :tree_opts, []))
    else
      # Host embeds {NostrEx.Supervisor, opts} in its own tree.
      :ignore
    end
  end
end
