defmodule NostrEx.RelayManager do
  @moduledoc """
  A Dynamic Supervisor which supervises connections to relays.

  Nostr clients typically connect to multiple relays.
  When you `connect/1` to a relay, a child of this Supervisor is started, implemented by `NostrEx.Socket`.
  This process can be referenced by its `pid` or by the name it is registered under in the `Registry`.
  By default the registered name is the relay URL host with periods replaced by underscores `_`, e.g. "relay_example_com".
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
  Connect to the relay with `relay_url`.
  Starts a child of the `RelayManager` supervisor as a `Socket`.
  It will return `{:ok, pid}` if a relay with that `relay_url` is already connected.

  The `connect_to_relay/2` function called after successful `Socket.init` is asynchronous, and will block the caller until it completes. The handshake to set up the conn may take several seconds, and times out after 3 seconds by default.
  It is therefore recommendeded to run this function in a `Task`,
  in particular when connecting to multiple relays.
  Note that the return value is not necessarily needed, since you can call `Socket.get_status/1` to see if the connection is ready to send or receive messages.
  """
  @spec connect(String.t()) :: {:ok, pid()} | {:error, String.t()}
  def connect(relay_url) do
    with {:ok, uri} <- parse_url(relay_url),
         relay_name = Utils.name_from_host(uri.host),
         {:ok, pid} <- DynamicSupervisor.start_child(__MODULE__, {Socket, %{uri: uri, name: relay_name}}) do
        case connect_to_relay(pid) do
          {:ok, _pid} -> {:ok, relay_name}
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, {:already_started, pid}} ->
          name = Socket.get_status(pid) |> Map.get(:name)
          {:ok, name}
        {:error, reason} -> {:error, reason}
    end
  end

  @spec connect_to_relay(pid(), timeout()) :: {:ok, pid()} | {:error, String.t()}
  defp connect_to_relay(pid, timeout \\ 3_000) do
    case Socket.connect(pid) do
      {:ok, :connected} ->
        wait_for_ready(pid, 500, timeout)

      {:error, reason} ->
        disconnect(pid)
        {:error, reason}
    end
  end

  @spec wait_for_ready(pid(), pos_integer(), timeout(), non_neg_integer()) :: {:ok, pid()} | {:error, String.t()}
  defp wait_for_ready(pid, interval, timeout, elapsed_time \\ 0) do
    if elapsed_time >= timeout do
      {:error, "Relay is connected but not ready to receive messages after #{timeout}"}
    else
      if ready?(pid) do
        {:ok, pid}
      else
        Process.sleep(interval)
        wait_for_ready(pid, interval, timeout, elapsed_time + interval)
      end
    end
  end

  @spec ready?(pid() | atom()) :: boolean() | {:error, :not_found}
  def ready?(pid) when is_pid(pid), do: Socket.get_status(pid) |> Map.get(:ready?)

  def ready?(relay_name) do
    case lookup(relay_name) do
      {:ok, pid} -> ready?(pid)
      err -> err
    end
  end

  @spec disconnect(pid() | String.t() | atom()) :: :ok | {:error, term()}
  def disconnect(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  def disconnect(relay_name) when is_binary(relay_name) do
    String.to_atom(relay_name) |> disconnect()
  end

  def disconnect(relay_name) when is_atom(relay_name) do
    case lookup(relay_name) do
      {:ok, pid} -> disconnect(pid)
      err -> err
    end
  end

  @spec relays() :: [{:undefined, pid(), :worker, [module()]}]
  def relays(), do: DynamicSupervisor.which_children(__MODULE__)

  @spec active_pids() :: [pid()]
  def active_pids() do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.map(&get_pid/1)
  end

  @spec get_states() :: [%{url: String.t(), name: atom(), ready?: boolean(), closing?: boolean()}]
  def get_states() do
    active_pids() |> Enum.map(fn pid -> Socket.get_status(pid) end)
  end

  @spec registered_names() :: [atom()]
  def registered_names() do
    Registry.select(RelayRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()
  end

  @spec lookup(atom()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(name) do
    case Registry.lookup(RelayRegistry, name) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
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
      |> Map.update!(:host, fn host -> if host == "", do: nil, else: host end)

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
