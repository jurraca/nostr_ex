defmodule NostrEx.RelayManager do
  @moduledoc """
  A `DynamicSupervisor` which supervises connections to relays.

  Nostr clients typically connect to multiple relays.
  When you `connect/1` to a relay, a child of this Supervisor is started, implemented by `NostrEx.Socket`.
  This process can be referenced by its `pid` or by the name it is registered under in the `Registry`.
  By default the registered name is the relay URL host (lowercased), e.g. "relay.damus.io".
  Currently connected relays can be queried with:
  - `active_pids/0`: returns a list of this supervisor's children PIDs
  - `registered_names/0`: returns a list of Registry names for currently connected relay `pid`s.
  - `lookup/1`: takes a registered name, returns its `pid`
  - `get_states/0`: returns the `Socket.get_status/1` for each relay, which includes the URL and registered name
  - `relays/0`: a convenience for `DynamicSupervisor.which_children(Socket)`

  `Socket` functions only take a `pid` or a registered name to identify a relay.
  """

  use DynamicSupervisor
  alias NostrEx.{RelayRegistry, Socket, Utils}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(opts) do
    DynamicSupervisor.init(opts)
  end

  @doc """
  Ensure a socket exists for `relay_url` and wait for its first successful
  handshake (up to `:readiness_timeout` ms, default 5000).

  The Socket process drives its own connection attempts from spawn and
  reconnects with exponential backoff on any later failure, so an error
  return here does not stop the retry loop - the relay slot stays
  registered and observable via `get_states/0` while it keeps trying. When
  `:max_attempts` is set and exhausted, the socket terminates itself: the
  slot is removed and `{:relay_failed, name, attempts}` is broadcast on
  the `:relay_events` topic.

  ## Options
  - `:readiness_timeout` - ms to wait for the handshake (default 5000)
  - `:backoff_min` / `:backoff_max` - reconnect delay bounds (ms)
  - `:max_attempts` - reconnect attempts before giving up (default `:infinity`)
  """
  @spec connect(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def connect(relay_url, opts \\ []) do
    with {:ok, uri} <- parse_url(relay_url) do
      name = Utils.name_from_host(uri.host)

      case DynamicSupervisor.start_child(
             __MODULE__,
             {Socket, %{uri: uri, name: name, opts: opts}}
           ) do
        {:ok, _pid} ->
          :ok

        # Another caller already owns this relay slot; adopt it.
        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          {:error, inspect(reason)}
      end
      |> case do
        :ok -> wait_until_ready(name, Keyword.get(opts, :readiness_timeout, 5_000))
        error -> error
      end
    end
  end

  defp wait_until_ready(name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until_ready(name, deadline)
  end

  defp do_wait_until_ready(name, deadline) do
    cond do
      ready?(name) == true ->
        {:ok, name}

      System.monotonic_time(:millisecond) > deadline ->
        {:error, "relay #{name} not ready within readiness timeout"}

      true ->
        Process.sleep(20)
        do_wait_until_ready(name, deadline)
    end
  end

  @spec ready?(String.t()) :: boolean() | {:error, :not_found | String.t()}
  def ready?(relay_name) when is_binary(relay_name) do
    case lookup(relay_name) do
      {:ok, pid} ->
        case safe_status(pid) do
          {:ok, status} -> Map.get(status, :ready?)
          # Registry entries can outlive their process by an instant.
          :down -> false
        end

      err ->
        err
    end
  end

  def ready?(_),
    do:
      {:error,
       "relay name must be a string, see registered_names/0 for currently active relay names."}

  @spec disconnect(String.t()) :: :ok | {:error, term() | String.t()}
  def disconnect(relay_name) when is_binary(relay_name) do
    case lookup(relay_name) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      err -> err
    end
  end

  def disconnect(_),
    do:
      {:error,
       "relay name must be a string, see registered_names/0 for currently active relay names."}

  @spec relays() :: [{:undefined, pid(), :worker, [module()]}]
  def relays(), do: DynamicSupervisor.which_children(__MODULE__)

  @spec active_pids() :: [pid()]
  def active_pids() do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.map(&get_pid/1)
  end

  @spec get_states() :: [
          %{url: String.t(), name: String.t(), ready?: boolean(), closing?: boolean()}
        ]
  def get_states() do
    # Sockets may terminate concurrently with this enumeration; drop any
    # that vanish between snapshotting children and querying them.
    active_pids()
    |> Enum.flat_map(fn pid ->
      case safe_status(pid) do
        {:ok, status} -> [status]
        :down -> []
      end
    end)
  end

  @spec registered_names() :: [String.t()]
  def registered_names() do
    Registry.select(RelayRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()
  end

  @spec lookup(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(name) do
    case Registry.lookup(RelayRegistry, name) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  @spec safe_status(pid()) :: {:ok, map()} | :down
  defp safe_status(pid) do
    {:ok, Socket.get_status(pid)}
  catch
    :exit, _ -> :down
  end

  @spec parse_url(String.t()) :: {:ok, URI.t()} | {:error, String.t()}
  defp parse_url("http" <> _rest = url) do
    reason = "The relay URL must be a websocket, not an HTTP URL, got: #{url}"
    {:error, reason}
  end

  defp parse_url(url) do
    uri =
      URI.parse(url)
      |> Map.update!(:path, &(&1 || "/"))
      |> Map.update!(:host, fn
        nil -> nil
        "" -> nil
        host -> String.downcase(host)
      end)

    if uri.scheme in ["ws", "wss"] and uri.host do
      {:ok, uri}
    else
      {:error, "Invalid URL #{url} with host #{uri.host || "empty"}"}
    end
  end

  @spec get_pid({:undefined, pid(), :worker, [module()]} | term()) :: pid() | nil
  defp get_pid({:undefined, pid, :worker, [Socket]}), do: pid
  defp get_pid(_), do: nil
end
