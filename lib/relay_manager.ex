defmodule NostrEx.RelayManager do
  @moduledoc """
  A Dynamic Supervisor which supervises connections to relays.
  This module provides a few functions to faciliate getting the status of individual websocket conns.
  """

  use DynamicSupervisor
  alias NostrEx.{RelayRegistry, Socket, Utils}

  @name RelaySupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(opts)
  end

  @impl true
  def init(opts) do
    DynamicSupervisor.init(opts)
  end

  @doc """
  Connect to the relay with `relay_url`.
  Starts a child of the `RelayManager` supervisor as a `Socket`.
  It will return `{:error, "already connected"}` if a relay with that `relay_url` is already connected.

  The `connect_to_relay/2` function called after successful `Socket.init` is asynchronous, and will block the caller until it completes. The handshake to set up the conn may take several seconds, and times out after 3 seconds by default.
  It is therefore recommendeded to run this function in a `Task`,
  in particular when connecting to multiple relays.
  Note that the return value is not necessarily needed, since you can call `Socket.get_status/1` to see if the connection is ready to send or receive messages.
  """
  def connect(relay_url) do
    with {:ok, uri} <- parse_url(relay_url),
         relay_name = Utils.name_from_host(uri.host) do
      case DynamicSupervisor.start_child(@name, {Socket, %{uri: uri, name: relay_name}}) do
        {:ok, pid} -> connect_to_relay(pid)
        {:error, {:already_started, _pid}} -> {:error, "already connected"}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp connect_to_relay(pid, timeout \\ 3_000) do
    case Socket.connect(pid) do
      :ok ->
        wait_for_ready(pid, 500, timeout)

      {:error, reason} ->
        disconnect(pid)
        {:error, reason}
    end
  end

  def wait_for_ready(pid, interval, timeout, elapsed_time \\ 0) do
    if elapsed_time >= timeout do
      {:error, :not_ready}
    else
      if ready?(pid) do
        {:ok, pid}
      else
        Process.sleep(interval)
        wait_for_ready(pid, interval, timeout, elapsed_time + interval)
      end
    end
  end

  def ready?(pid) when is_pid(pid), do: Socket.get_status(pid) |> Map.get(:ready?)

  def ready?(relay_name) do
    case lookup(relay_name) do
      {:ok, pid} -> ready?(pid)
      err -> err
    end
  end

  def disconnect(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(@name, pid)
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

  def relays(), do: DynamicSupervisor.which_children(@name)

  def active_pids() do
    @name
    |> DynamicSupervisor.which_children()
    |> Enum.map(&get_pid/1)
  end

  def get_states() do
    active_pids() |> Enum.map(fn pid -> Socket.get_status(pid) end)
  end

  def registered_names() do
    Registry.select(RelayRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()
  end

  def lookup(name) do
    case Registry.lookup(RelayRegistry, name) do
      [{pid, _}] -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

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

  defp get_pid({:undefined, pid, :worker, [Socket]}), do: pid
  defp get_pid(_), do: nil
end
