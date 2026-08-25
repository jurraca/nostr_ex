defmodule NostrEx.RelayManager do
  @moduledoc """
  A `DynamicSupervisor` which supervises connections to relays.

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
  Starts a child of the `RelayManager` supervisor as a `Socket`, then performs
  the websocket handshake, blocking until the relay is ready or the handshake
  fails (3 second timeout by default).
  It will return `{:ok, name}` if a relay with that `relay_url` is already connected.
  """
  @spec connect(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def connect(relay_url) do
    with {:ok, uri} <- parse_url(relay_url) do
      do_connect(uri, Utils.name_from_host(uri.host), attempts: 2)
    end
  end

  @adopt_wait_ms 1_500

  @spec do_connect(URI.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp do_connect(uri, relay_name, opts) do
    case DynamicSupervisor.start_child(__MODULE__, {Socket, %{uri: uri, name: relay_name}}) do
      {:ok, pid} ->
        claim_new_child(pid, relay_name)

      # Another caller already owns (or raced us on) this relay's socket.
      # Adopt it: wait for readiness, and replace it if it never becomes ready.
      {:error, {:already_started, pid}} ->
        if wait_until_ready(pid, @adopt_wait_ms) do
          {:ok, relay_name}
        else
          _ = terminate_quietly(pid)
          retry_or_fail(uri, relay_name, opts)
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp claim_new_child(pid, relay_name) do
    case Socket.connect(pid) do
      {:ok, :connected} ->
        {:ok, relay_name}

      {:error, reason} ->
        # The handshake failed; make sure the child is cleaned up.
        _ = terminate_quietly(pid)
        {:error, reason}
    end
  end

  defp retry_or_fail(uri, relay_name, opts) do
    case Keyword.fetch!(opts, :attempts) - 1 do
      0 -> {:error, "relay process unavailable"}
      remaining -> do_connect(uri, relay_name, Keyword.put(opts, :attempts, remaining))
    end
  end

  # Waits up to `timeout` ms for the socket at `pid` to finish its handshake.
  # Treats a momentarily-unregistered (dying/restarting) child as "keep waiting".
  @spec wait_until_ready(pid(), pos_integer()) :: boolean()
  defp wait_until_ready(pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_until_ready(pid, deadline)
  end

  defp do_wait_until_ready(pid, deadline) do
    if ready_now?(pid) do
      true
    else
      if System.monotonic_time(:millisecond) > deadline do
        false
      else
        Process.sleep(20)
        do_wait_until_ready(pid, deadline)
      end
    end
  end

  defp ready_now?(pid) do
    match?(%{ready?: true}, Socket.get_status(pid))
  catch
    :exit, _ -> false
  end

  defp terminate_quietly(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  catch
    :exit, _ -> :ok
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
